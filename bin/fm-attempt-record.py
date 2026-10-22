#!/usr/bin/env python3
"""Append one private attempt record before releasing a task's worktree.

Usage: python3 bin/fm-attempt-record.py --task-id ID --meta FILE --data DIR
The caller holds the task metadata lock and has stopped its worker. The ledger
is DIR/attempts.jsonl (0600). An exclusive file lock serializes concurrent
writers; fsync completes before success. Retries keep the first record for
(task_id, attempt_id), including its original end time. Invalid ledger data
refuses the append; callers warn and continue rather than block on telemetry.

fm-spawn.sh owns attempt_id and attempt_started_at. Same-profile replacements
retain them and all sessions in [attempt_started_at, end) are counted by
fm-attempt-usage.py. --end accepts Unix seconds or a timezone-qualified ISO
timestamp, defaulting to now; --claude-root/--codex-root forward log locations.
--end bounds attribution and becomes ts. ended_at and duration_s use the
attempt's last counted usage event, falling back to --end with a note.
Older metadata uses spawn_gen (or a metadata digest) for retry identity, but
does not infer a usage interval from mutable file times or reused paths.

Policy fields without a source remain null with notes. Pool is not inferred
from a model or harness name. Lifecycle evidence comes from the exact project,
branch and attempt interval in no-mistakes' read-only state database, plus the
validated PR merge receipt. Review labels are never translated to policy
severities. Accepted remains unknown until the seven-day fix-forward check.
--relaunch HARNESS MODEL TIER closes an attempt only when those axes change
(or a previous interrupted relaunch already closed it), printing the durable
ts for the replacement's start; if recording fails it still prints --end and
exits nonzero. Same-profile handoffs print nothing. Only a rise in the leading
T<n> of the tier label is escalated; other changes close with a null outcome
and a note naming the switch.
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
import re
import subprocess
import sqlite3
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


def tier_rank(label):
    match = re.match(r"T(\d+)\b", label or "")
    return int(match.group(1)) if match else None


def shell_read(script, *args):
    return subprocess.check_output(["bash", "-c", script, "attempt-record", *map(str, args)],
                                   text=True, stderr=subprocess.DEVNULL, timeout=15).strip()


def lifecycle(args, meta, start, end, notes):
    result = dict(gate_result=None, outcome=None, review_model=None,
                  review_findings=dict.fromkeys(("blocker", "major", "minor")), merged=None)
    scripts = Path(__file__).parent
    try:
        shell_read('''source "$1/fm-pr-lib.sh"
fm_pr_metadata_identity_parse "$2" &&
fm_pr_poll_merge_already_notified "$3" "$4" "$FM_PR_META_PROVIDER" \
  "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER"
''', scripts, args.meta, args.meta.parent, args.task_id)
        result["merged"] = True
    except (OSError, subprocess.SubprocessError):
        notes.append("Validated merge receipt unavailable.")
    notes.append("Acceptance awaits fix_forward_7d; a merge alone is not acceptance.")
    if start is None or not meta.get("project") or not meta.get("branch"):
        notes.append("No-mistakes attribution needs project, branch and attempt start.")
        return result
    try:
        db = shell_read('source "$1/fm-nm-run-lib.sh"; fm_nm_state_db "$2"',
                        scripts, meta.get("worktree", ""))
        with sqlite3.connect(Path(db).absolute().as_uri() + "?mode=ro", uri=True, timeout=2) as conn:
            conn.row_factory = sqlite3.Row
            # Historical attempts need every run, not just the current run selected
            # by fm_nm_select_run. Exact repo, branch and start prevent path reuse.
            runs = conn.execute(
                "SELECT runs.* FROM runs JOIN repos ON runs.repo_id=repos.id "
                "WHERE repos.working_path=? AND branch=? AND created_at>=? AND created_at<? "
                "ORDER BY created_at,id", (meta["project"], meta["branch"], start, end)).fetchall()
            if not runs:
                notes.append("No no-mistakes run attributed to this attempt.")
                return result
            result["nm_run_ids"] = [run["id"] for run in runs]
            # A later write cannot describe the state at this attempt's boundary.
            if any(run["updated_at"] > end for run in runs):
                notes.append("No-mistakes records changed after attempt end; lifecycle unknown.")
                return result
            latest = runs[-1]
            steps = conn.execute("SELECT * FROM step_results WHERE run_id=?",
                                 (latest["id"],)).fetchall()
            try:
                shell_read('source "$1/fm-nm-run-lib.sh"; fm_nm_head_matches_worktree "$2" "$3"',
                           scripts, meta.get("worktree", ""), latest["head_sha"] or "")
                head_matches = True
            except (OSError, subprocess.SubprocessError):
                head_matches = False
                notes.append("No-mistakes head does not match task code; gate result unknown.")
            if head_matches:
                if any(step["status"] == "failed" for step in steps):
                    result["gate_result"] = "red"
                elif latest["ci_ready_at"] and latest["ci_ready_at"] <= end:
                    result["gate_result"] = "green"
            if latest["status"] == "failed":
                result["outcome"] = "failed"
            counts = dict.fromkeys(("blocker", "major", "minor"), 0)
            models, review_seen, unknown, corrected = set(), False, False, False
            for run in runs:
                seen = set()
                reviews = conn.execute("SELECT * FROM step_results WHERE run_id=? AND step_name='review'",
                                       (run["id"],)).fetchall()
                for review in reviews:
                    rounds = conn.execute("SELECT * FROM step_rounds WHERE step_result_id=? ORDER BY round",
                                          (review["id"],)).fetchall()
                    corrected |= any(row["repair_published"] == 1 for row in rounds)
                    documents = [row["findings_json"] for row in rounds] + [review["findings_json"]]
                    for raw in documents:
                        if not raw:
                            unknown = True
                            continue
                        document = json.loads(raw)
                        if not isinstance(document, dict):
                            raise ValueError("review findings must be an object")
                        findings = document.get("findings")
                        if not isinstance(findings, list):
                            unknown = True
                            continue
                        review_seen = True
                        for finding in findings:
                            if not isinstance(finding, dict) or finding.get("severity") not in counts:
                                unknown = True
                                continue
                            # Repeated findings across fix rounds charge once per run.
                            identity = finding.get("id")
                            if not identity:
                                unknown = True
                                continue
                            key = (identity, finding["severity"])
                            if key not in seen:
                                counts[finding["severity"]] += 1
                                seen.add(key)
                for row in conn.execute("SELECT model FROM agent_invocations WHERE run_id=? "
                                        "AND step_name='review' AND purpose='review'", (run["id"],)):
                    models.add(row["model"] or None)
            if review_seen and not unknown:
                result["review_findings"] = counts
            else:
                notes.append("Policy review severities unavailable; native error/warning/info are not mapped.")
            if len(models) == 1 and None not in models:
                result["review_model"] = models.pop()
            else:
                notes.append("Review model unavailable or multiple reviewer models recorded.")
            if corrected and result["outcome"] is None:
                result["outcome"] = "corrected"
    except (OSError, ValueError, TypeError, KeyError, IndexError, sqlite3.Error, subprocess.SubprocessError):
        # Optional evidence cannot make cleanup destroy or invent measurements.
        notes.append("No-mistakes lifecycle evidence unavailable or schema unsupported.")
    for field in ("gate_result", "outcome"):
        if result[field] is None:
            notes.append(f"{field} not established by lifecycle evidence.")
    return result


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
    usage_fields = ("input_tokens", "output_tokens", "cache_read_tokens",
                    "cache_write_tokens", "context_peak")
    record.update(dict.fromkeys(usage_fields))
    finished = None
    if start is not None and worktree and os.path.isabs(worktree):
        if record["harness"] in ("claude", "codex"):
            command = [sys.executable, str(Path(__file__).with_name("fm-attempt-usage.py")),
                       "--harness", record["harness"], "--worktree", worktree,
                       "--start", str(start), "--end", str(end)]
            for name in ("claude_root", "codex_root"):
                if getattr(args, name):
                    command.extend(["--" + name.replace("_", "-"), getattr(args, name)])
            try:
                usage = json.loads(subprocess.check_output(command, text=True))
                record.update({field: usage[field] for field in usage_fields})
                notes.extend(usage["notes"])
                finished = usage["last_activity"]
            except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
                notes.append("Usage logs unreadable; usage not attributed.")
        else:
            notes.append("Usage extraction unavailable for this harness.")
    elif not worktree or not os.path.isabs(worktree):
        notes.append("Absolute task worktree unavailable; usage not attributed.")
    if finished is None:
        finished = end
        notes.append("No recorded worker activity; ended_at is the cleanup time.")
    record.update(ts=iso(end), task_id=args.task_id, attempt_id=attempt_id,
                  started_at=iso(start) if start is not None else None,
                  ended_at=iso(finished), worktree=worktree,
                  duration_s=finished - start if start is not None else None)
    record.update(lifecycle(args, meta, start, end, notes))
    if args.relaunch:
        harness, model, tier = args.relaunch
        prior, rank = tier_rank(record["tier"]), tier_rank(tier)
        if prior is not None and rank is not None and rank > prior:
            record["outcome"] = "escalated"
        else:
            record["outcome"] = None
            if tier == (record["tier"] or ""):
                notes.append(f"Lateral switch at tier {tier or 'unknown'}: "
                             f"{record['harness']}/{meta.get('model') or 'default'} -> "
                             f"{harness}/{model}; not an escalation.")
            else:
                notes.append(f"Tier changed from {record['tier']} to {tier or 'unknown'} "
                             "without a recorded rise; not an escalation.")
    record.update(fix_forward_7d=None, don_minutes=None)
    notes.append("fix_forward_7d and don_minutes not collected yet.")
    record["notes"] = sorted(set(notes))
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--meta", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--end", default=str(datetime.now(timezone.utc).timestamp()))
    parser.add_argument("--relaunch", nargs=3, metavar=("HARNESS", "MODEL", "TIER"))
    parser.add_argument("--claude-root")
    parser.add_argument("--codex-root")
    args = parser.parse_args()
    changed = False
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
        if args.relaunch:
            prior = [meta.get("harness", ""), meta.get("model") or "default", meta.get("tier", "")]
            changed = args.relaunch != prior
        args.data.mkdir(parents=True, exist_ok=True)
        ledger = args.data / "attempts.jsonl"
        fd = os.open(ledger, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a+", encoding="utf-8") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.seek(0)
            found = None
            for line in stream:
                entry = json.loads(line)
                if not line.endswith("\n") or not isinstance(entry, dict):
                    raise ValueError("incomplete or invalid attempt ledger record")
                if not entry.get("task_id") or not entry.get("attempt_id"):
                    raise ValueError("attempt ledger record lacks identity")
                if (entry["task_id"], entry["attempt_id"]) == (args.task_id, attempt_id):
                    found = entry
            if args.relaunch and found is None and not changed:
                return 0
            if found is None:
                record = build_record(args, meta, attempt_id, end)
                stream.write(json.dumps(record, sort_keys=True) + "\n")
                stream.flush()
                found = record
            os.fsync(stream.fileno())
        # Persist creation of the ledger itself, not only its contents.
        directory = os.open(args.data, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        if args.relaunch:
            print(found["ts"])
    except (OSError, ValueError, KeyError, OverflowError, subprocess.CalledProcessError) as error:
        print(f"Cannot record attempt: {error}", file=sys.stderr)
        if changed:
            print(iso(end))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
