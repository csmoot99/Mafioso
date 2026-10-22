#!/usr/bin/env python3
"""Append one private attempt record before releasing a task's worktree.

Usage: python3 bin/fm-attempt-record.py --task-id ID --meta FILE --data DIR
The caller holds the task metadata lock and has stopped its worker. The ledger
is DIR/attempts.jsonl (0600). An exclusive file lock serializes concurrent
writers; fsync completes before success. Retries keep the first record for
(task_id, attempt_id), including its original end time. Invalid ledger data
refuses the append so cleanup can preserve the remaining evidence.

fm-spawn.sh owns attempt_id and attempt_started_at. Same-profile replacements
retain them and all sessions in [attempt_started_at, end) are counted by
fm-attempt-usage.py. --end accepts Unix seconds or a timezone-qualified ISO
timestamp, defaulting to now; --claude-root/--codex-root forward log locations.
Older metadata uses spawn_gen (or a metadata digest) for retry identity, but
does not infer a usage interval from mutable file times or reused paths.

Policy fields without a source remain null with notes. Pool is not inferred
from a model or harness name. Lifecycle and review fields are not yet collected.
Additional attempt_id, started_at, ended_at and worktree fields preserve the
attribution boundary. No transcript text or credentials enter the ledger.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys


def timestamp(value):
    try:
        result = float(value)
    except (TypeError, ValueError):
        date = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if date.tzinfo is None:
            raise ValueError("timestamp must include a timezone")
        result = date.timestamp()
    if not math.isfinite(result):
        raise ValueError("timestamp must be finite")
    return result


def iso(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


def build_record(args, meta, attempt_id, end):
    record = {field: meta.get(field) or None for field in
              ("row", "tier", "harness", "pool", "model", "effort", "prior_tier")}
    notes = [f"{field} not recorded in task metadata." for field, value in record.items()
             if value is None]
    attempt_n = meta.get("attempt_n", "")
    if attempt_n.isascii() and attempt_n.isdigit() and int(attempt_n) > 0:
        record["attempt_n"] = int(attempt_n)
    else:
        record["attempt_n"] = None
        notes.append("attempt_n not recorded as a positive integer.")
    start = None
    if meta.get("attempt_started_at"):
        start = timestamp(meta["attempt_started_at"])
        if start >= end:
            raise ValueError("attempt start must precede end")
    else:
        notes.append("Attempt start unavailable; usage and duration not attributed.")
    worktree = meta.get("worktree") or None
    record.update(ts=iso(end), task_id=args.task_id, attempt_id=attempt_id,
                  started_at=iso(start) if start is not None else None,
                  ended_at=iso(end), worktree=worktree,
                  duration_s=end - start if start is not None else None)
    usage_fields = ("input_tokens", "output_tokens", "cache_read_tokens",
                    "cache_write_tokens", "context_peak")
    record.update(dict.fromkeys(usage_fields))
    if start is not None and worktree and os.path.isabs(worktree):
        if record["harness"] in ("claude", "codex"):
            command = [sys.executable, str(Path(__file__).with_name("fm-attempt-usage.py")),
                       "--harness", record["harness"], "--worktree", worktree,
                       "--start", str(start), "--end", str(end)]
            for name in ("claude_root", "codex_root"):
                if getattr(args, name):
                    command.extend(["--" + name.replace("_", "-"), getattr(args, name)])
            usage = json.loads(subprocess.check_output(command, text=True))
            record.update({field: usage[field] for field in usage_fields})
            notes.extend(usage["notes"])
        else:
            notes.append("Usage extraction unavailable for this harness.")
    elif not worktree or not os.path.isabs(worktree):
        notes.append("Absolute task worktree unavailable; usage not attributed.")
    record.update(gate_result=None, outcome=None, review_model=None,
                  review_findings=dict.fromkeys(("blocker", "major", "minor")),
                  fix_forward_7d=None, don_minutes=None)
    notes.append("Lifecycle gate, outcome, review model and findings not collected yet.")
    notes.append("fix_forward_7d and don_minutes not collected yet.")
    record["notes"] = sorted(set(notes))
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--meta", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--end", default=str(datetime.now(timezone.utc).timestamp()))
    parser.add_argument("--claude-root")
    parser.add_argument("--codex-root")
    args = parser.parse_args()
    try:
        raw = args.meta.read_bytes()
        meta = {}
        for line in raw.decode("utf-8").splitlines():
            key, separator, value = line.partition("=")
            if separator and key not in meta:
                meta[key] = value
        attempt_id = (meta.get("attempt_id") or meta.get("spawn_gen")
                      or "legacy-" + hashlib.sha256(raw).hexdigest())
        end = timestamp(args.end)
        args.data.mkdir(parents=True, exist_ok=True)
        ledger = args.data / "attempts.jsonl"
        fd = os.open(ledger, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a+", encoding="utf-8") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.seek(0)
            found = False
            for line in stream:
                entry = json.loads(line)
                if not line.endswith("\n") or not isinstance(entry, dict):
                    raise ValueError("incomplete or invalid attempt ledger record")
                if not entry.get("task_id") or not entry.get("attempt_id"):
                    raise ValueError("attempt ledger record lacks identity")
                found |= (entry["task_id"], entry["attempt_id"]) == (args.task_id, attempt_id)
            if not found:
                record = build_record(args, meta, attempt_id, end)
                stream.write(json.dumps(record, sort_keys=True) + "\n")
                stream.flush()
            os.fsync(stream.fileno())
        # Persist creation of the ledger itself, not only its contents.
        directory = os.open(args.data, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except (OSError, ValueError, OverflowError, subprocess.CalledProcessError) as error:
        print(f"Cannot record attempt: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
