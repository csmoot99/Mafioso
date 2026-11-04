#!/usr/bin/env python3
"""Remote half of bin/fm-heavy-remote.sh: run one transferred job and report it.

Usage: fm-heavy-remote-runner.py start|supervise|status|reconcile|wait|cancel|cleanup <jobdir> [seconds]

The client ships this file with each job, so nothing is installed on the remote
host. It needs only python3 (stdlib), git and ps, and runs on macOS and Linux.
A job directory lives under ~/.fm-heavy-remote and holds manifest.json (job id,
candidate sha, command argv and its digest, bundle digest, timeout) and
src.bundle (the candidate revision with its history).

start     Refuses a second start of the same job, verifies the bundle and command
          digests, clones the bundle, checks out and verifies the exact sha, then
          launches a detached supervisor and prints "started". It exits 10 on any
          refusal, having launched nothing, and 11 when the supervisor it launched
          recorded no owner in time, so the job may still have started.
supervise Runs the command in its own process group with cwd the checkout, output
          to run.log, enforcing the timeout and killing the whole group on
          timeout, cancel or exit. It then publishes result.json atomically; that
          file is the durable completion record. Its fields: schema, id, sha and
          tree read back from the checkout, command_sha256, bundle_sha256,
          outcome (exited, timeout or cancelled), exit_code (128+n for a signal),
          started_at, ended_at, run_s, cpu_usec, host, and artifacts (bytes and
          sha256 of run.log).
status    Prints absent, preparing, running, done, or lost (the supervisor died
          without publishing a result).
reconcile status, for a job its client lost touch with: lost becomes orphaned when
          the command group outlived its supervisor, and preparing becomes lost
          when a start recorded no owner within the job's timeout, since it died.
wait      status, polled until it stops being running or preparing or the seconds
          given elapse.
cancel    Asks the supervisor to stop the job's own group and waits for the result.
cleanup   Stops anything the job still owns, then removes the job directory.

Only processes this job started are ever signalled: the supervisor and the command
group are recorded with their start times in owner.json, and a pid whose start
time differs is left alone.
"""

import hashlib
import json
import os
import re
import resource
import shutil
import signal
import socket
import subprocess
import sys
import time

ROOT = os.path.join(os.path.expanduser("~"), ".fm-heavy-remote")
SCHEMA = "fm-heavy-remote.v1"


def die(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(value, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def read_json(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def proc_start(pid):
    result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def alive(pid, start):
    return bool(start) and proc_start(pid) == start


def owned_group(owner):
    """The command's process group id, unless its pid now belongs to someone else."""
    group = owner.get("group")
    return group if group and proc_start(group) in ("", owner.get("group_start")) else None


def signal_group(group, sig):
    """Whether the group took the signal; macOS answers EPERM for a group of zombies."""
    try:
        os.killpg(group, sig)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def group_alive(owner):
    group = owned_group(owner)
    return bool(group) and signal_group(group, 0)


def kill_group(owner, proc=None):
    """Stop the command's process group; a reused pid is left alone."""
    group = owned_group(owner)
    if not group:
        return
    for sig, patience in ((signal.SIGTERM, 3.0), (signal.SIGKILL, 0.0)):
        if not signal_group(group, sig):
            return
        end = time.monotonic() + patience
        while time.monotonic() < end:
            if proc is not None:
                proc.poll()
            if not signal_group(group, 0):
                return
            time.sleep(0.1)


def job_dir(arg):
    path = os.path.realpath(arg)
    if os.path.dirname(path) != os.path.realpath(ROOT) or not re.fullmatch(r"[A-Za-z0-9._-]+", os.path.basename(path)):
        die(10, "refused: %s is not a job directory under %s" % (arg, ROOT))
    return path


def status(jdir):
    if not os.path.isdir(jdir):
        return "absent"
    if os.path.exists(os.path.join(jdir, "result.json")):
        return "done"
    owner = read_json(os.path.join(jdir, "owner.json"))
    if owner is None:
        return "preparing" if os.path.exists(os.path.join(jdir, "started")) else "absent"
    if alive(owner["supervisor_pid"], owner["supervisor_start"]):
        return "running"
    # The supervisor may have published its result between the two checks.
    return "done" if os.path.exists(os.path.join(jdir, "result.json")) else "lost"


def reconcile_state(jdir):
    state = status(jdir)
    if state == "lost" and group_alive(read_json(os.path.join(jdir, "owner.json")) or {}):
        return "orphaned"
    if state == "preparing":
        manifest = read_json(os.path.join(jdir, "manifest.json")) or {}
        if time.time() - os.path.getmtime(os.path.join(jdir, "started")) > manifest.get("timeout_s", 0):
            return "lost"
    return state


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def cmd_start(jdir):
    try:
        os.close(os.open(os.path.join(jdir, "started"), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    except FileExistsError:
        die(10, "refused: job %s was already started" % os.path.basename(jdir))
    manifest = read_json(os.path.join(jdir, "manifest.json"))
    if not manifest or manifest.get("id") != os.path.basename(jdir):
        die(10, "refused: manifest missing or for another job")
    argv, sha = manifest.get("argv"), manifest.get("sha", "")
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        die(10, "refused: manifest has no command")
    if not isinstance(manifest.get("timeout_s"), int) or manifest["timeout_s"] < 1 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        die(10, "refused: manifest timeout or sha invalid")
    if hashlib.sha256(b"".join(a.encode() + b"\0" for a in argv)).hexdigest() != manifest.get("command_sha256"):
        die(10, "refused: command digest mismatch")
    bundle = os.path.join(jdir, "src.bundle")
    if not os.path.isfile(bundle) or sha256_file(bundle) != manifest.get("bundle_sha256"):
        die(10, "refused: source bundle digest mismatch")
    work = os.path.join(jdir, "work")
    cloned = git("clone", "-q", "--no-checkout", bundle, work)
    if cloned.returncode or git("-C", work, "checkout", "-q", "--detach", sha).returncode:
        die(10, "refused: could not check out %s: %s" % (sha, cloned.stderr.strip()))
    if git("-C", work, "rev-parse", "HEAD").stdout.strip() != sha:
        die(10, "refused: checkout is not %s" % sha)
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "supervise", jdir], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    end = time.monotonic() + 15
    while not os.path.exists(os.path.join(jdir, "owner.json")):
        if time.monotonic() > end:
            die(11, "supervisor did not start")
        time.sleep(0.1)
    print("started")


def cmd_supervise(jdir):
    manifest = read_json(os.path.join(jdir, "manifest.json"))
    work = os.path.join(jdir, "work")
    stops = []
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: stops.append(1))
    started_at, began = int(time.time()), time.monotonic()
    log = open(os.path.join(jdir, "run.log"), "wb")
    outcome, code = "exited", 127
    try:
        proc = subprocess.Popen(manifest["argv"], cwd=work, stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as error:
        log.write(("cannot run %s: %s\n" % (manifest["argv"][0], error)).encode())
        proc = None
    owner = {"supervisor_pid": os.getpid(), "supervisor_start": proc_start(os.getpid()),
             "group": proc.pid if proc else None, "group_start": proc_start(proc.pid) if proc else ""}
    write_json(os.path.join(jdir, "owner.json"), owner)
    if proc:
        while proc.poll() is None:
            if stops:
                outcome = "cancelled"
            elif time.monotonic() - began > manifest["timeout_s"]:
                outcome = "timeout"
            else:
                time.sleep(0.2)
                continue
            kill_group(owner, proc)
        code = proc.wait()
        code = 128 - code if code < 0 else code
        kill_group(owner)  # anything the command left running
        if stops and outcome == "exited":
            outcome = "cancelled"
    log.close()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    artifact = os.path.join(jdir, "run.log")
    write_json(os.path.join(jdir, "result.json"), {
        "schema": SCHEMA, "id": manifest["id"],
        "sha": git("-C", work, "rev-parse", "HEAD").stdout.strip(),
        "tree": git("-C", work, "rev-parse", "HEAD^{tree}").stdout.strip(),
        "command_sha256": manifest["command_sha256"], "bundle_sha256": manifest["bundle_sha256"],
        "outcome": outcome, "exit_code": code, "started_at": started_at, "ended_at": int(time.time()),
        "run_s": round(time.monotonic() - began, 3), "cpu_usec": int((usage.ru_utime + usage.ru_stime) * 1e6),
        "host": socket.gethostname(),
        "artifacts": {"run.log": {"bytes": os.path.getsize(artifact), "sha256": sha256_file(artifact)}}})


def cmd_wait(jdir, seconds):
    end = time.monotonic() + seconds
    state = status(jdir)
    while state in ("running", "preparing") and time.monotonic() < end:
        time.sleep(0.3)
        state = status(jdir)
    print(state)


def await_owner(jdir):
    """A start still in flight has not yet recorded what it launched; give it time to."""
    end = time.monotonic() + 5
    while (os.path.exists(os.path.join(jdir, "started")) and not os.path.exists(os.path.join(jdir, "owner.json"))
           and time.monotonic() < end):
        time.sleep(0.1)


def cmd_cancel(jdir):
    await_owner(jdir)
    owner = read_json(os.path.join(jdir, "owner.json"))
    if owner and alive(owner["supervisor_pid"], owner["supervisor_start"]):
        os.kill(owner["supervisor_pid"], signal.SIGTERM)
        end = time.monotonic() + 20
        while status(jdir) == "running" and time.monotonic() < end:
            time.sleep(0.2)
    elif owner:
        kill_group(owner)
    print(status(jdir))


def cmd_cleanup(jdir):
    await_owner(jdir)
    owner = read_json(os.path.join(jdir, "owner.json"))
    if owner:
        if alive(owner["supervisor_pid"], owner["supervisor_start"]):
            os.kill(owner["supervisor_pid"], signal.SIGTERM)
            end = time.monotonic() + 20
            while alive(owner["supervisor_pid"], owner["supervisor_start"]) and time.monotonic() < end:
                time.sleep(0.2)
        kill_group(owner)
    shutil.rmtree(jdir, ignore_errors=True)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("start", "supervise", "status", "reconcile", "wait", "cancel", "cleanup"):
        die(2, "usage: fm-heavy-remote-runner.py start|supervise|status|reconcile|wait|cancel|cleanup <jobdir> [seconds]")
    action, jdir = sys.argv[1], job_dir(sys.argv[2])
    if action == "status":
        print(status(jdir))
    elif action == "reconcile":
        print(reconcile_state(jdir))
    elif action == "wait":
        cmd_wait(jdir, float(sys.argv[3]) if len(sys.argv) > 3 else 0)
    else:
        {"start": cmd_start, "supervise": cmd_supervise, "cancel": cmd_cancel, "cleanup": cmd_cleanup}[action](jdir)


if __name__ == "__main__":
    main()
