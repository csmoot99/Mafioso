#!/usr/bin/env python3
"""Read one attempt's Claude or Codex usage; emit JSON, never transcript text.

The caller owns the task's exclusive worktree interval [start, end), in UTC.
The launch cwd selects Claude's project directory or Codex's session header;
event cwd changes do not change attribution. Event timestamps are required,
and multiple sessions in that interval are summed.
Claude requests (including subagents) are deduplicated by message id, keeping
the latest usage. Codex cumulative counters deduplicate repeated token_count
notifications and supply deltas; last_token_usage supplies context peak and a
fallback when cumulative counters are absent or reset. A first counter from a
session predating the interval uses only last_token_usage without a baseline.

input_tokens is Claude's uncached input. Codex input_tokens includes
cached_input_tokens, which is subtracted here; reasoning output is
already included in output_tokens. Context peak follows the existing handoff
readers: Claude input plus caches; Codex last_token_usage.total_tokens.
Missing measurements are null with notes, never inferred as zero. Missing
fields in any counted request make that aggregate field null. Session counts
include only sessions with counted usage. last_activity is the Unix time of
the latest counted usage event, or null. Roots can be supplied for account
stores or fixtures; defaults honor CLAUDE_CONFIG_DIR and CODEX_HOME.
"""

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import sys


FIELDS = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")


def timestamp(value):
    try:
        result = float(value)
    except (TypeError, ValueError):
        date = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if date.tzinfo is None:
            raise ValueError("timestamps must include a timezone")
        result = date.astimezone(timezone.utc).timestamp()
    if not math.isfinite(result):
        raise ValueError("timestamps must be finite")
    return result


def event_time(record):
    try:
        return timestamp(record.get("timestamp"))
    except (ValueError, TypeError, OverflowError):
        return None


def obj(value):
    return value if isinstance(value, dict) else {}


def count(value):
    return value if type(value) is int and value >= 0 else None


def add(values):
    return sum(values) if all(v is not None for v in values) else None


def usage(raw, harness):
    raw = obj(raw)
    if harness == "claude":
        keys = ("input_tokens", "output_tokens", "cache_read_input_tokens",
                "cache_creation_input_tokens")
        return [count(raw.get(k)) for k in keys]
    values = [count(raw.get(k)) for k in
              ("input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens")]
    if values[0] is not None:
        cached = values[2]
        values[0] = (values[0] - cached
                     if cached is not None and values[0] >= cached else None)
    return values


def records(stream, notes):
    for line in stream:
        try:
            record = json.loads(line)
        except (ValueError, UnicodeError):
            notes.add("Malformed JSONL record skipped; usage may be incomplete.")
            continue
        if isinstance(record, dict):
            yield record


def claude_requests(root, worktree, start, end, notes):
    project = root / re.sub(r"[^a-zA-Z0-9]", "-", worktree)
    messages = {}
    paths = sorted(project.glob("*.jsonl")) + sorted(project.glob("*/subagents/*.jsonl"))
    for path in paths:
        with path.open(encoding="utf-8", errors="replace") as stream:
            for record in records(stream, notes):
                if record.get("type") != "assistant":
                    continue
                ts = event_time(record)
                message = obj(record.get("message"))
                mid = message.get("id")
                if ts is None or not isinstance(mid, str) or not message.get("usage"):
                    notes.add("Claude assistant record lacks timestamp, message id or usage.")
                    continue
                session = path.stem if path.parent == project else path.parent.parent.name
                # Only retain measurement metadata, not prompts or tool payloads.
                if mid not in messages or ts >= messages[mid][0]:
                    messages[mid] = (ts, session, usage(message["usage"], "claude"))
    for ts, session, values in messages.values():
        if start <= ts < end:
            yield session, values, add([values[0], values[2], values[3]]), ts


def codex_requests(root, worktree, start, end, notes):
    sessions = {}
    for path in sorted(root.rglob("*.jsonl")):
        with path.open(encoding="utf-8", errors="replace") as stream:
            # Inspect only the header until ownership is established.
            try:
                header = obj(json.loads(next(stream)))
            except (StopIteration, ValueError):
                continue
            meta = obj(header.get("payload"))
            if header.get("type") != "session_meta" or meta.get("cwd") != worktree:
                continue
            sid = meta.get("id")
            if not isinstance(sid, str) or not sid:
                notes.add("Codex session without id skipped; cannot deduplicate it.")
                continue
            session = sessions.setdefault(sid, {"start": event_time(header), "events": {}})
            for record in records(stream, notes):
                payload = obj(record.get("payload"))
                info = obj(payload.get("info"))
                if record.get("type") != "event_msg" or payload.get("type") != "token_count" or not info:
                    continue
                ts = event_time(record)
                if ts is None:
                    notes.add("Codex token_count without timestamp skipped.")
                    continue
                if ts >= end:
                    continue
                total = obj(info.get("total_token_usage"))
                last = obj(info.get("last_token_usage"))
                # Copies of the same rollout must not add another request.
                key = (ts, json.dumps([total, last], sort_keys=True))
                session["events"][key] = (ts, total, last)
    for sid, session in sessions.items():
        previous = None
        for index, (ts, total, last) in enumerate(sorted(session["events"].values(), key=lambda e: e[0])):
            before = previous
            previous = total or None
            if ts < start:
                continue
            if total and before == total:
                continue
            values = usage(last, "codex")
            if total:
                baseline = usage(before, "codex") if before else None
                if index == 0 and session["start"] is not None and session["start"] >= start:
                    baseline = [0] * len(FIELDS)
                if baseline is not None:
                    current = usage(total, "codex")
                    delta = [a - b if a is not None and b is not None else fallback
                             for a, b, fallback in zip(current, baseline, values)]
                    if any(a is None or b is None for a, b in zip(current, baseline)):
                        notes.add("Codex cumulative fields missing; used available last_token_usage fields.")
                    if any(v is not None and v < 0 for v in delta):
                        notes.add("Codex cumulative counters reset; used last_token_usage.")
                    else:
                        values = delta
                else:
                    notes.add("Codex usage without a baseline in the interval; used last_token_usage.")
            else:
                notes.add("Codex cumulative counters missing; last_token_usage cannot deduplicate repeated notifications.")
            yield sid, values, count(last.get("total_tokens")), ts


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--harness", required=True, choices=("claude", "codex"))
    parser.add_argument("--worktree", required=True, help="Exact absolute cwd recorded at dispatch")
    parser.add_argument("--start", required=True, help="Inclusive Unix seconds or timezone-qualified ISO timestamp")
    parser.add_argument("--end", required=True, help="Exclusive Unix seconds or timezone-qualified ISO timestamp")
    parser.add_argument("--claude-root", type=Path, default=Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "projects")
    parser.add_argument("--codex-root", type=Path, default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "sessions")
    args = parser.parse_args()
    try:
        start, end = timestamp(args.start), timestamp(args.end)
    except (ValueError, OverflowError) as error:
        parser.error(str(error))
    if not os.path.isabs(args.worktree) or start >= end:
        parser.error("worktree must be absolute and start must precede end")
    notes = set()
    sessions = set()
    totals = [0] * len(FIELDS)
    peaks = []
    last_activity = None
    root = args.claude_root if args.harness == "claude" else args.codex_root
    extractor = claude_requests if args.harness == "claude" else codex_requests
    try:
        if not root.is_dir():
            notes.add("Transcript root is missing.")
        for session, values, peak, ts in extractor(root, args.worktree, start, end, notes):
            sessions.add(session)
            totals = [add([a, b]) for a, b in zip(totals, values)]
            peaks.append(peak)
            last_activity = ts if last_activity is None else max(last_activity, ts)
    except OSError as error:
        # Do not publish partial totals as complete when a log could not be read.
        print(f"Cannot read usage logs: {error}", file=sys.stderr)
        return 1
    if not sessions:
        totals = [None] * len(FIELDS)
        notes.add("No attributable usage in the requested worktree interval.")
    result = dict(zip(FIELDS, totals))
    result["context_peak"] = max(peaks) if peaks and None not in peaks else None
    for field, value in result.items():
        if value is None and sessions:
            notes.add(f"{field} unavailable in one or more usage records.")
    result.update(sessions=len(sessions), last_activity=last_activity, notes=sorted(notes))
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
