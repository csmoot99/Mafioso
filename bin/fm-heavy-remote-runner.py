#!/usr/bin/env python3
"""Remote half of bin/fm-heavy-remote.sh: run one transferred job and report it.

Usage: fm-heavy-remote-runner.py start|supervise|status|reconcile|wait|cancel|cleanup <jobdir> [seconds]

The client ships this file with each job, so nothing is installed on the remote
host. It needs python3 (stdlib), git and ps, and runs on macOS and Linux.
Node projects also need the node and pnpm/npm versions they pin installed on the
host: on the SSH PATH, under ~/.nvm/versions/node, or under
~/.fm-heavy-remote/runtimes/<tool>/<version>/bin. execute puts the versions this
job's project pins first on its PATH, prepares locked dependencies and then execs
the approved command in the supervised process group; preparation failures exit
78 and a command that cannot run exits 127, never a local fallback.
Dependency copies persist per project under ~/.fm-heavy-remote/cache, keyed by
lockfile/package settings and runtime versions. Each job has private modules.
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

import fcntl
import glob
import hashlib
import json
import os
import re
import resource
import shlex
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


def version_tuple(value):
    match = re.fullmatch(r"v?(\d+)(?:\.(\d+))?(?:\.(\d+))?", value.strip())
    if not match:
        raise ValueError("unsupported version: " + value)
    return tuple(int(part or 0) for part in match.groups())


def satisfies(version, requirement):
    """Common stable npm ranges; unsupported syntax refuses rather than guesses."""
    actual = version_tuple(version)
    for alternative in requirement.split("||"):
        alternative = alternative.strip()
        hyphen = re.fullmatch(r"(\d+\.\d+\.\d+)\s+-\s+(\d+\.\d+\.\d+)", alternative)
        if hyphen:
            if version_tuple(hyphen[1]) <= actual <= version_tuple(hyphen[2]):
                return True
            continue
        terms = re.sub(r"([<>=~^]+)\s+", r"\1", alternative).split()
        if not terms:
            raise ValueError("empty runtime requirement")
        accepted = True
        for term in terms:
            if term in ("*", "x", "X"):
                continue
            match = re.fullmatch(r"(>=|<=|>|<|=|\^|~)?v?(\d+)(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?", term)
            if not match:
                raise ValueError("unsupported runtime range: " + requirement)
            op = match[1] or "="
            parts = match.groups()[1:]
            precision = next((i for i, part in enumerate(parts) if part is None or part in ("x", "X", "*")), 3)
            target = tuple(int(part) if part and part.isdigit() else 0 for part in parts)
            upper = list(target)
            if op == "^":
                index = next((i for i, part in enumerate(target[:precision]) if part), precision - 1)
            elif op == "~":
                index = min(precision - 1, 1)
            else:
                index = precision - 1
            upper[index] += 1
            upper[index + 1:] = [0] * (2 - index)
            upper = tuple(upper)
            if op in ("^", "~") or (op == "=" and precision < 3):
                ok = target <= actual < upper
            else:
                boundary = upper if precision < 3 and op in (">", "<=") else target
                ok = {"=": actual == boundary, ">=": actual >= boundary, "<=": actual < boundary if precision < 3 else actual <= boundary,
                      ">": actual >= boundary if precision < 3 else actual > boundary, "<": actual < boundary}[op]
            accepted = accepted and ok
        if accepted:
            return True
    return False


def installed_bins(tool):
    """Bin directories of the tool's versions installed on this host, newest first."""
    roots = [os.path.join(ROOT, "runtimes", tool)]
    if tool == "node":
        roots.append(os.path.join(os.path.expanduser("~"), ".nvm", "versions", "node"))
    bins = [path for root in roots for path in glob.glob(os.path.join(root, "*", "bin"))]
    return sorted(bins, key=lambda path: [int(part) for part in re.findall(r"\d+", os.path.basename(os.path.dirname(path)))], reverse=True)


def select_runtime(tool, requirements):
    """Put the first version meeting the project's pins first on this job's PATH."""
    found = []
    for directory in [None] + installed_bins(tool):
        try:
            version = subprocess.check_output([os.path.join(directory, tool) if directory else tool, "--version"],
                                              text=True, stderr=subprocess.STDOUT).strip()
        except (OSError, subprocess.CalledProcessError):
            continue
        found.append(version)
        if all(isinstance(requirement, str) and satisfies(version, requirement) for requirement in requirements):
            if directory:
                os.environ["PATH"] = directory + os.pathsep + os.environ["PATH"]
            return version
    if not found:
        raise ValueError("missing runtime %s; install the project's version on the host" % tool)
    raise ValueError("runtime %s %s does not satisfy %s; install the project's version on the host"
                     % (tool, ", ".join(found), " and ".join(str(requirement) for requirement in requirements)))


def module_dirs(work):
    for base, dirs, _ in os.walk(work):
        dirs[:] = [name for name in dirs if name != ".git"]
        if "node_modules" in dirs:
            dirs.remove("node_modules")
            yield os.path.relpath(os.path.join(base, "node_modules"), work)


def prepare_dependencies(work, manifest):
    package_path = os.path.join(work, "package.json")
    package = read_json(package_path)
    if package is None:
        if os.path.exists(package_path):
            raise ValueError("invalid package.json")
        return
    if not isinstance(package, dict) or not isinstance(package.get("engines", {}), dict) or not isinstance(package.get("packageManager", ""), str):
        raise ValueError("invalid package.json runtime declarations")
    locks = [name for name in ("pnpm-lock.yaml", "npm-shrinkwrap.json", "package-lock.json") if os.path.isfile(os.path.join(work, name))]
    if not locks:
        raise ValueError("package.json has no supported lockfile (pnpm-lock.yaml, npm-shrinkwrap.json or package-lock.json)")
    if "pnpm-lock.yaml" in locks and len(locks) != 1:
        raise ValueError("ambiguous pnpm/npm lockfiles")
    manager = "pnpm" if locks[0] == "pnpm-lock.yaml" else "npm"
    engines = package.get("engines", {})
    node_requirements = [engines["node"]] if "node" in engines else []
    nvmrc = os.path.join(work, ".nvmrc")
    if os.path.isfile(nvmrc):
        with open(nvmrc) as handle:
            node_requirements.append(handle.read().strip())
    node = select_runtime("node", node_requirements)
    requirements = [engines[manager]] if manager in engines else []
    pinned = package.get("packageManager", "")
    if pinned:
        prefix = manager + "@"
        if not pinned.startswith(prefix):
            raise ValueError("packageManager disagrees with lockfile: " + pinned)
        requirements.append(pinned[len(prefix):].split("+", 1)[0])
    version = select_runtime(manager, requirements)
    key = hashlib.sha256(manifest["project"].encode()).hexdigest()
    cache = os.path.join(ROOT, "cache", key)
    os.makedirs(cache, exist_ok=True)
    digest = hashlib.sha256((node + "\0" + manager + version).encode())
    settings = git("-C", work, "ls-files", "-z", "**/package.json", "**/.npmrc").stdout.split("\0")
    for name in sorted(set(locks + ["package.json", ".nvmrc", ".npmrc", "pnpm-workspace.yaml"] + settings)):
        path = os.path.join(work, name)
        if os.path.isfile(path):
            digest.update((name + "\0" + sha256_file(path)).encode())
    fingerprint = digest.hexdigest()
    # Lock only preparation/copying, never a test run.
    with open(os.path.join(cache, "lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        marker = read_json(os.path.join(cache, "installed.json"))
        modules = os.path.join(cache, "modules")
        if marker and marker.get("fingerprint") == fingerprint and os.path.isdir(modules):
            for relative in module_dirs(modules):
                shutil.copytree(os.path.join(modules, relative), os.path.join(work, relative), symlinks=True)
        else:
            command = [manager, "install", "--frozen-lockfile", "--prod=false"] if manager == "pnpm" else [manager, "ci", "--include=dev"]
            subprocess.run(command, cwd=work, check=True)
            # Never leave a previous marker attesting to a partially replaced cache.
            try:
                os.unlink(os.path.join(cache, "installed.json"))
            except FileNotFoundError:
                pass
            shutil.rmtree(modules, ignore_errors=True)
            os.makedirs(modules)
            for relative in module_dirs(work):
                shutil.copytree(os.path.join(work, relative), os.path.join(modules, relative), symlinks=True)
            write_json(os.path.join(cache, "installed.json"), {"fingerprint": fingerprint})
    if manifest.get("class") == "e2e" and needs_playwright(manifest["argv"], package):
        # Playwright itself caches browser revisions per account; its installer
        # only downloads revisions missing for this checkout's installed version.
        command = ["pnpm", "exec", "playwright", "install"] if manager == "pnpm" else ["npm", "exec", "--no", "--", "playwright", "install"]
        subprocess.run(command, cwd=work, check=True)


def needs_playwright(argv, package):
    scripts = package.get("scripts", {})
    if not isinstance(scripts, dict) or not all(isinstance(value, str) for value in scripts.values()):
        raise ValueError("invalid package.json scripts")
    pending = list(argv)
    seen = set()
    while pending:
        word = pending.pop()
        if os.path.basename(word) == "playwright":
            return True
        if word in scripts and word not in seen:
            seen.add(word)
            pending.extend(shlex.split(scripts[word]))
    return False


def cmd_execute(jdir):
    manifest = read_json(os.path.join(jdir, "manifest.json"))
    try:
        prepare_dependencies(os.path.join(jdir, "work"), manifest)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        die(78, "remote dependency/runtime preparation failed: %s" % error)
    try:
        os.execvp(manifest["argv"][0], manifest["argv"])
    except OSError as error:
        die(127, "cannot run %s: %s" % (manifest["argv"][0], error))


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
        proc = subprocess.Popen([sys.executable, os.path.abspath(__file__), "execute", jdir], cwd=work, stdin=subprocess.DEVNULL, stdout=log,
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
    if len(sys.argv) < 3 or sys.argv[1] not in ("start", "supervise", "execute", "status", "reconcile", "wait", "cancel", "cleanup"):
        die(2, "usage: fm-heavy-remote-runner.py start|supervise|status|reconcile|wait|cancel|cleanup <jobdir> [seconds]")
    action, jdir = sys.argv[1], job_dir(sys.argv[2])
    if action == "status":
        print(status(jdir))
    elif action == "reconcile":
        print(reconcile_state(jdir))
    elif action == "wait":
        cmd_wait(jdir, float(sys.argv[3]) if len(sys.argv) > 3 else 0)
    else:
        {"start": cmd_start, "supervise": cmd_supervise, "execute": cmd_execute, "cancel": cmd_cancel, "cleanup": cmd_cleanup}[action](jdir)


if __name__ == "__main__":
    main()
