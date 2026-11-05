#!/usr/bin/env python3
"""The test-failure ledger behind bin/fm-test-failure.sh, which owns the contract."""
import argparse
import collections
import json
import os
import re
import subprocess
import sys
import time

CLASSES = ("regression", "stale", "brittle", "new-code", "preventable", "flaky")
TEXT_MAX = 300
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
VITEST_JEST_FAIL = re.compile(r"^\s*FAIL\s+(?:\|[^|]*\|\s+)?(.+)$")
FILE_SUFFIX = re.compile(r"\s+(?:\[ .* \]|\([\d.]+ m?s\))$")
JEST_BULLET = re.compile(r"^\s*●\s+(.+)$")
MARK = re.compile(r"^\s*[×✕✗✘✖]\s+(.+)$")
ASCII_MARK = re.compile(r"^\s*x\s+(.+)$")
DURATION = re.compile(r"\s+(?:\(?[\d.]+\s?m?s\)?|\(retry #\d+\))$")
VITEST_FILE = re.compile(r"^\s*❯\s+(\S+)\s+\(\d+ tests?\b")
NODE_LOCATION = re.compile(r"^\s*test at (.+?):\d+:\d+$")
SUMMARY = re.compile(r"^\s*Tests:?\s+\d+ failed")
PW_TITLE = re.compile(r"^(?:\[([^\]]+)\]\s+›\s+)?(?:›\s+)?(\S+?):\d+(?::\d+)?\s+›\s+(.+?)(?:\s+─+)?$")
PW_MARK = re.compile(r"^\s*[✘✗×]\s+(?:\d+\s+)?(.+)$")
PW_NUMBERED = re.compile(r"^\s*\d+\)\s+(.+)$")
PW_FAILED = re.compile(r"^\s*\d+ failed\s*$")
TAP_NOT_OK = re.compile(r"^\s*not ok\b(?:\s+\d+)?(?:\s+-)?\s*(.*)$")
TAP_NEXT = re.compile(r"^\s*(?:not )?ok\b")
TAP_DIRECTIVE = re.compile(r"#\s*(?:todo|skip)\b", re.I)
TAP_LOCATION = re.compile(r"^\s*location:\s*'?(.+?):\d+:\d+'?$")
TAP_ERROR = re.compile(r"^\s*error:\s*(.*)$")
BATS_LOCATION = re.compile(r"^#\s+\(in test file (.+?), line \d+\)$")
ERROR_WORD = re.compile(r"\b(?:error|failed|failure)\b", re.I)


def clean(text):
    return " ".join(text.split())[:TEXT_MAX]


def joined(title):
    return " > ".join(part.strip() for part in title.split(" › "))


def first_error(lines, index):
    """The first line after a failure header that says something."""
    for line in lines[index + 1:index + 16]:
        text = line.strip()
        if JEST_BULLET.match(line) or MARK.match(line) or TAP_NEXT.match(line) or text.startswith("ℹ"):
            return None
        if text and not VITEST_JEST_FAIL.match(line) and not text.startswith("Retry #") and set(text) - set("⎯─-="):
            return clean(text)
    return None


def playwright_title(text):
    text = DURATION.sub("", DURATION.sub("", text.strip()))
    match = PW_TITLE.match(text)
    return (match.group(1), match.group(2), joined(match.group(3))) if match else None


def tap_failure(lines, index):
    """Returns (file, error) for a not ok line, or None for a parent of failed subtests."""
    file = error = None
    for offset, line in enumerate(lines[index + 1:index + 40], index + 1):
        if TAP_NEXT.match(line):
            break
        if "failureType: 'subtestsFailed'" in line:
            return None
        location = TAP_LOCATION.match(line) or BATS_LOCATION.match(line)
        if location:
            file = file or location.group(1)
            continue
        found = TAP_ERROR.match(line)
        if found and not error:
            value = found.group(1).strip("'\" ")
            if value in ("|", "|-", ">", ">-") and offset + 1 < len(lines):
                value = lines[offset + 1]
            error = clean(value)
        elif not error and line.startswith("#") and not line.startswith("# Subtest"):
            error = clean(line.lstrip("# "))
    return file, error


def parse_failures(text):
    """Failing tests in reporter output, as {file, test, error} dicts.

    Each reporter names a failure twice, so a detailed entry (vitest FAIL, jest
    bullet, the Playwright failed list, a TAP not ok) wins and the running marks
    count only in output that has no detailed entry at all.
    """
    lines = [ANSI.sub("", line).rstrip() for line in text.splitlines()]
    detailed, marked, playwright_errors = {}, {}, {}
    has_summary = any(SUMMARY.match(line) for line in lines)
    current_file = None
    in_playwright_list = False

    def add(rows, key, file, test, error):
        row = rows.setdefault(key, {"file": None, "test": test, "error": None})
        row["file"] = row["file"] or file
        row["error"] = row["error"] or error

    for index, line in enumerate(lines):
        if in_playwright_list:
            title = playwright_title(line)
            if title:
                add(detailed, title, title[1], title[2], playwright_errors.get(title))
                continue
            in_playwright_list = False
        if PW_FAILED.match(line):
            in_playwright_list = True
            continue

        match = VITEST_JEST_FAIL.match(line)
        if match:
            path, _, test = match.group(1).partition(" > ")
            error = first_error(lines, index)
            if test:
                test = joined(test.replace(" > ", " › "))
                add(detailed, (path, test), path, test, error)
            else:
                current_file = FILE_SUFFIX.sub("", path)
                if path.endswith(" ]"):
                    add(detailed, (current_file, "Test suite failed to run"), current_file, "Test suite failed to run", error)
            continue

        match = JEST_BULLET.match(line)
        if match:
            if match.group(1) != "Console":
                test = joined(match.group(1))
                add(detailed, (current_file, test), current_file, test, first_error(lines, index))
            continue

        match = TAP_NOT_OK.match(line)
        if match:
            name = match.group(1)
            found = None if TAP_DIRECTIVE.search(name) else tap_failure(lines, index)
            if found:
                test = clean(name.split(" # ")[0]) or "(unnamed)"
                add(detailed, ("tap", test, found[0]), found[0], test, found[1])
            continue

        match = PW_NUMBERED.match(line)
        title = playwright_title(match.group(1)) if match else None
        if title:
            playwright_errors[title] = first_error(lines, index)
            add(marked, title, title[1], title[2], playwright_errors[title])
            continue

        match = PW_MARK.match(line)
        title = playwright_title(match.group(1)) if match else None
        if title:
            add(marked, title, title[1], title[2], None)
            continue

        match = VITEST_FILE.match(line) or NODE_LOCATION.match(line)
        if match:
            current_file = match.group(1)
            continue

        match = MARK.match(line) or (has_summary and ASCII_MARK.match(line))
        if match and match.group(1) != "failing tests:":
            test = joined(DURATION.sub("", match.group(1)))
            add(marked, test, current_file, test, first_error(lines, index))

    rows = list((detailed or marked).values())
    if rows:
        return rows
    error = next((clean(line) for line in lines if ERROR_WORD.search(line)), None)
    return [{"file": None, "test": "(unparsed)", "error": error}]


def safe_name(name):
    return re.sub(r"[^A-Za-z0-9._-]", "_", name or "").lstrip(".") or "unknown"


def ledger_dir(root):
    return os.path.join(root, "data", "test-failures")


def ledger_path(root, project):
    return os.path.join(ledger_dir(root), safe_name(project) + ".jsonl")


def append(root, project, entries):
    os.makedirs(ledger_dir(root), exist_ok=True)
    data = "".join(json.dumps(entry, ensure_ascii=False) + "\n" for entry in entries)
    descriptor = os.open(ledger_path(root, project), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(descriptor, data.encode())
    finally:
        os.close(descriptor)


def read_entries(root, project=None):
    """Ledger lines in time order; a torn or foreign line is skipped."""
    if project:
        paths = [ledger_path(root, project)]
    else:
        try:
            names = sorted(os.listdir(ledger_dir(root)))
        except OSError:
            names = []
        paths = [os.path.join(ledger_dir(root), name) for name in names if name.endswith(".jsonl")]
    entries = []
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as ledger:
                for line in ledger:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(entry, dict) and entry.get("kind") in ("failure", "classification"):
                        entries.append(entry)
        except OSError:
            continue
    entries.sort(key=lambda entry: entry.get("ts") or 0)
    return entries


def git_output(*args):
    try:
        done = subprocess.run(("git",) + args, capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    return (done.stdout.strip() or None) if done.returncode == 0 else None


def capture(root, args):
    try:
        with open(args.log, encoding="utf-8", errors="replace") as log:
            text = log.read()
    except OSError:
        text = ""
    top = git_output("rev-parse", "--show-toplevel")
    project = safe_name(args.project)
    base = {
        "kind": "failure", "ts": int(time.time()), "project": project, "task": args.task or None,
        "class": args.job_class, "command": args.job_command[:TEXT_MAX],
        "branch": git_output("branch", "--show-current"), "head": git_output("rev-parse", "HEAD"),
        "job": args.job, "log": args.log,
    }
    entries = []
    for row in parse_failures(text):
        file = row["file"]
        if file and top and file.startswith(top + os.sep):
            file = os.path.relpath(file, top)  # worktree paths differ per task
        entries.append({**base, "file": file, "test": row["test"], "error": row["error"]})
    append(root, project, entries)
    return 0


def matches(entry, test, file):
    name = entry.get("test") or ""
    if name != test and not name.endswith(" > " + test):
        return False
    return not file or (entry.get("file") or "").endswith(file)


def task_project(root, task):
    """The project of a task the ledger has no line for, from its task record."""
    if not re.fullmatch(r"[A-Za-z0-9._-]+", task):
        return None
    for home in (os.environ.get("FM_HOME"), root):
        try:
            with open(os.path.join(home or root, "state", task + ".meta"), encoding="utf-8", errors="replace") as meta:
                for line in meta:
                    if line.startswith("project="):
                        return os.path.basename(line[len("project="):].strip().rstrip("/"))
        except OSError:
            continue
    return None


def classify(root, args):
    cause = clean(args.cause)
    if not cause:
        print("fm-test-failure.sh: --cause needs one line of text", file=sys.stderr)
        return 2
    failures = [e for e in read_entries(root) if e["kind"] == "failure" and e.get("task") == args.task]
    linked = next((e for e in reversed(failures) if matches(e, args.test, args.file)), None)
    source = linked or (failures[-1] if failures else None)
    project = source.get("project") if source else task_project(root, args.task)
    if not project:
        print(f"fm-test-failure.sh: no ledger for task {args.task}: it has no recorded failure or task record", file=sys.stderr)
        return 1
    append(root, project, [{
        "kind": "classification", "ts": int(time.time()), "project": project, "task": args.task,
        "test": linked["test"] if linked else args.test,
        "file": linked.get("file") if linked else args.file,
        "class": args.failure_class, "cause": cause, "job": linked.get("job") if linked else None,
    }])
    if not linked:
        print(f"fm-test-failure.sh: no recorded failure of {args.test} in task {args.task}; classification kept unlinked", file=sys.stderr)
    return 0


def print_counts(title, counts, limit=None):
    print(f"{title}:")
    for name, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:limit]:
        print(f"  {count}  {name}")


def report(root, args):
    match = re.fullmatch(r"([0-9]+)d", args.since or "0d")
    if not match:
        print("fm-test-failure.sh: --since needs <days>d, for example 7d", file=sys.stderr)
        return 2
    cutoff = time.time() - int(match.group(1)) * 86400 if args.since else 0
    entries = read_entries(root, args.project)
    failures = [e for e in entries if e["kind"] == "failure" and (e.get("ts") or 0) >= cutoff]
    classes = [e for e in entries if e["kind"] == "classification" and (e.get("ts") or 0) >= cutoff]
    if not failures and not classes:
        print("no test failures recorded")
        return 0
    newest = {}  # the latest classification of each linked test in a task
    for entry in entries:
        if entry["kind"] == "classification" and entry.get("job"):
            newest[(entry.get("task"), entry.get("file"), entry.get("test"))] = entry.get("ts") or 0
    unclassified = sum(
        1 for e in failures
        if (e.get("ts") or 0) > newest.get((e.get("task"), e.get("file"), e.get("test")), -1)
    )
    share = round(unclassified * 100 / len(failures)) if failures else 0
    print(f"failures: {len(failures)}")
    print(f"unclassified: {unclassified} of {len(failures)} ({share}%)")
    print_counts("per project", collections.Counter(e.get("project") for e in failures))
    print_counts("per class", collections.Counter(e.get("class") for e in classes))
    tests = collections.Counter(f"{e.get('file')} > {e.get('test')}" if e.get("file") else e.get("test") for e in failures)
    print_counts("most repeated tests", tests, 10)
    print_counts("most implicated files", collections.Counter(e["file"] for e in failures if e.get("file")), 10)
    return 0


def recent(root, args):
    if args.limit < 1:
        print("fm-test-failure.sh: --limit needs a positive number", file=sys.stderr)
        return 2
    for entry in read_entries(root, args.project)[-args.limit:]:
        when = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(entry.get("ts") or 0))
        detail = entry.get("cause") if entry["kind"] == "classification" else entry.get("error")
        print("\t".join(str(value or "-") for value in (
            when, entry.get("project"), entry.get("task"), entry["kind"], entry.get("class"),
            entry.get("file"), entry.get("test"), detail)))
    return 0


def main():
    root = sys.argv[1]
    parser = argparse.ArgumentParser(prog="fm-test-failure.sh")
    commands = parser.add_subparsers(dest="command", required=True)
    sub = commands.add_parser("capture")
    sub.add_argument("--log", required=True)
    sub.add_argument("--job", required=True)
    sub.add_argument("--task", default="")
    sub.add_argument("--project", default="")
    sub.add_argument("--class", dest="job_class", required=True)
    sub.add_argument("--command", dest="job_command", required=True)
    sub.set_defaults(run=capture)
    sub = commands.add_parser("classify")
    sub.add_argument("task")
    sub.add_argument("--test", required=True)
    sub.add_argument("--file")
    sub.add_argument("--class", dest="failure_class", choices=CLASSES, required=True)
    sub.add_argument("--cause", required=True)
    sub.set_defaults(run=classify)
    sub = commands.add_parser("report")
    sub.add_argument("--project")
    sub.add_argument("--since")
    sub.set_defaults(run=report)
    sub = commands.add_parser("recent")
    sub.add_argument("--project")
    sub.add_argument("--limit", type=int, default=20)
    sub.set_defaults(run=recent)
    args = parser.parse_args(sys.argv[2:])
    return args.run(root, args)


if __name__ == "__main__":
    sys.exit(main())
