#!/usr/bin/env python3
"""Remote half of bin/fm-heavy-remote.sh: run one transferred job and report it.

Usage: fm-heavy-remote-runner.py busy [host-slots]
       fm-heavy-remote-runner.py start|status|reconcile|cancel|cleanup <jobdir>
       fm-heavy-remote-runner.py wait <jobdir> [seconds]
Internal launches:
       fm-heavy-remote-runner.py guard <jobdir> <slot-fd>
       fm-heavy-remote-runner.py supervise <jobdir> <slot-fd> <ready-fd>
       fm-heavy-remote-runner.py container|execute <jobdir> [<slot-fd> <ready-fd> <supervisor-pid> <supervisor-start>]

The client ships this file with each job, so nothing is installed on the remote
host. It needs python3 (stdlib), git and ps, and runs on macOS and Linux.
Node projects also need the node and npm versions they pin, and any pnpm, installed
on the host: on the SSH PATH, under ~/.nvm/versions/node, or under
~/.fm-heavy-remote/runtimes/<tool>/<version>/bin. A reachable pnpm may fetch the
version a project pins for itself, and then reports that version. execute puts
the versions this job's project pins first on its PATH, prepares locked
dependencies and then execs the approved command in the supervised process group;
runtime/dependency preparation errors exit 78; supervised preparation failures
report prepare-failed for local fallback, preserving their exit status. A
command that cannot run exits 127 and remains a command failure.
Dependency copies persist per project under ~/.fm-heavy-remote/cache, keyed by
lockfile/package settings and runtime versions. Each job has private modules.
A job directory lives under ~/.fm-heavy-remote and holds manifest.json (project,
class, job id, candidate sha, command argv and its digest, bundle digest,
timeout, image, nofile, services and job env) and src.bundle (the candidate revision with its history).

Host slots: host_slots in the manifest (default 1, range 1-64) includes the
host's own jobs on FM_HEAVY_HOST_LOCK (default /tmp/fm-heavy.lock). Additional
slots use <lock>.remote.<number>, preferred over the original lock so native
jobs can still start unchanged. A detached guard retains the kernel lock until
both the supervisor exits and the reported command group stops, including any
surviving descendants. Supervisor loss therefore cannot free capacity for either
native or remote admission. The command closes its inherited slot descriptor
before preparing dependencies or launching the approved command.
Live <lock>.waiting pid markers and childless `flock <lock> <command>` processes
prevent admission, preserving priority for native jobs already waiting. Descriptor
forms of flock are matched through /proc on Linux or the system lsof on macOS.
No running job is stopped for another.

busy      Prints busy and exits 12 when capacity is full or native work awaits, else
          prints free. It needs no job directory.
start     Exits 12, having created nothing, when capacity is full or native work
          awaits. Otherwise it refuses a second start of the same job, verifies the bundle and command
          digests, clones the bundle, checks out and verifies the exact sha, then
          launches a detached guard and supervisor and prints "started". It exits
          10 on any refusal, having launched nothing, and 11 when no owner was
          recorded in time after launch, so the job may still have started.
guard     Owns the slot lifetime described above; receives the command group's
          identity over a pipe independently of the supervisor's survival.
supervise Runs the command in its own process group with cwd the checkout, output
          to run.log, enforcing the timeout and killing the whole group on
          timeout, cancel or exit. It then publishes result.json atomically; that
          file is the durable completion record. Its fields: schema, id, sha and
          tree read back from the checkout, command_sha256, bundle_sha256,
          outcome (exited, prepare-failed, timeout or cancelled), preparation_step, exit_code (128+n for a signal),
          started_at, ended_at, run_s, cpu_usec, host, and artifacts (bytes and
          sha256 of run.log).
          preparation_step is container-start, services, runtime, dependencies,
          browsers or command. A nonzero exit or timeout before command is
          prepare-failed; cancellation remains cancelled at every step.
status    Prints absent, preparing, running, done, or lost (the supervisor died
          without publishing a result).
reconcile status, for a job its client lost touch with: lost becomes orphaned when
          the command group outlived its supervisor, and preparing becomes lost
          when a start recorded no owner within the job's timeout, since it died.
wait      status, polled until it stops being running or preparing or the seconds
          given elapse.
cancel    Asks the supervisor to stop the job's own group and waits for the result.
cleanup   Stops anything the job still owns, then removes the job directory.

Container: a manifest image runs the execute step inside that Linux image with
docker (on the SSH PATH, /opt/homebrew/bin or /usr/local/bin), named
fm-heavy-<job>, capped at 6g with no swap, the job directory mounted at the same
path and ~/.fm-heavy-remote/linux/runtimes and linux/cache standing in for
runtimes and cache, so Linux runtimes and dependency copies never mix with the
host's own. The container's Playwright browsers, pnpm store and npm cache live
under that cache's tools directory, so they persist across jobs. Stopping the job also removes that container. A missing docker fails
preparation with exit 127, allowing a local retry. The manifest nofile sets
the container soft/hard open-file limits (default 65536).

Services: each manifest service runs as its own container, fm-heavy-<job>-<name>,
capped at its declared memory with no swap and given its declared env. The first
joins a new private network fm-heavy-<job> that publishes no port; the others and
the job container share its network namespace, so the job reaches each service on
localhost:<port> and nothing else reaches them. The container step starts them
inside the supervised group, so the job's timeout and cancel cover image pulls;
execute applies the manifest env and waits up to 180 s for every service port
(exit 78 otherwise). start refuses with exit 13 when 6 GiB plus the services'
memory exceeds docker's total memory. Whenever the job ends, the job container,
its services and its network are removed by those exact names; no other docker
object is ever touched.

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
HOST_LOCK = os.environ.get("FM_HEAVY_HOST_LOCK", "/tmp/fm-heavy.lock")
BUSY = 12


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


def host_waiting():
    """Firstmate waiter markers and unchanged `flock <path> <command>` jobs.

    A flock command waiting in the kernel has no command child yet. A holder
    has already forked its command (or execed it with --no-fork). Treat the
    brief interval before that fork conservatively as waiting too.
    """
    for marker in glob.glob(glob.escape(HOST_LOCK) + ".waiting/*"):
        try:
            os.kill(int(os.path.basename(marker)), 0)
        except (ValueError, ProcessLookupError):
            continue
        except PermissionError:
            pass
        return True
    processes = subprocess.run(["ps", "-axo", "pid=,ppid=,comm=,args="], capture_output=True, text=True)
    if processes.returncode:
        return True  # Cannot prove native priority, so do not admit a job.
    rows = [line.split(None, 3) for line in processes.stdout.splitlines()]
    children = {row[1] for row in rows if len(row) == 4}
    for row in rows:
        if len(row) != 4 or os.path.basename(row[2]) != "flock" or row[0] in children:
            continue
        try:
            words = shlex.split(row[3])
        except ValueError:
            return True
        if any(word.startswith("/") and os.path.realpath(word) == os.path.realpath(HOST_LOCK) for word in words[1:]):
            return True
        # Descriptor-form flock has no path in argv. Inspect only this waiting
        # flock's descriptors, never other homes' files or processes' contents.
        if sys.platform == "linux":
            paths = glob.glob("/proc/%s/fd/*" % row[0])
            if any(os.path.realpath(path) == os.path.realpath(HOST_LOCK) for path in paths):
                return True
        else:
            lsof = shutil.which("lsof") or ("/usr/sbin/lsof" if os.path.isfile("/usr/sbin/lsof") else None)
            if not lsof:
                return True
            result = subprocess.run([lsof, "-a", "-p", row[0], "-Fn", HOST_LOCK], capture_output=True, text=True)
            if result.returncode not in (0, 1) or any(line.startswith("n") for line in result.stdout.splitlines()):
                return True
    return False


def take_host_slot(slots=1):
    """Take one kernel-owned slot without waiting; native jobs keep slot one.

    The module header owns slot ordering, native priority and lock lifetime.
    """
    if host_waiting():
        return None
    for number in [*range(2, slots + 1), 1]:
        path = HOST_LOCK if number == 1 else HOST_LOCK + ".remote.%d" % number
        try:
            fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o666)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(fd)
                continue
        except OSError as error:
            die(BUSY, "busy: cannot open %s: %s" % (path, error))
        if host_waiting():
            os.close(fd)
            return None
        return fd
    return None


def host_slots(value):
    if not re.fullmatch(r"[1-9][0-9]?", str(value)) or int(value) > 64:
        die(10, "refused: host-slots must be 1-64")
    return int(value)


def cmd_busy(slots=1):
    slot = take_host_slot(slots)
    if slot is None:
        print("busy")
        sys.exit(BUSY)
    os.close(slot)
    print("free")


def container(manifest):
    return "fm-heavy-" + manifest["id"]


def service_name(manifest, service):
    return container(manifest) + "-" + service["name"]


def remove_container(manifest):
    """Killing the docker client does not stop its containers, so remove them and the network by name."""
    docker = find_docker()
    if not (manifest.get("image") and docker):
        return
    services = manifest.get("services") or []
    names = [container(manifest)] + [service_name(manifest, s) for s in reversed(services)]
    for args in [["rm", "-f", name] for name in names] + ([["network", "rm", container(manifest)]] if services else []):
        subprocess.run([docker, *args], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def memory_bytes(value):
    return int(value[:-1]) << (30 if value[-1] == "g" else 20)


def find_docker():
    return shutil.which("docker", path=os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin")


def group_command(jdir, manifest):
    """The supervised command: the runner's execute step, or its container step when an image is set."""
    return [sys.executable, os.path.abspath(__file__), "container" if manifest.get("image") else "execute", jdir]


def cmd_container(jdir):
    """Start the job's private network and services, then become the job container's docker client."""
    manifest = read_json(os.path.join(jdir, "manifest.json"))
    image, services = manifest["image"], manifest.get("services") or []
    docker = find_docker()
    if not docker:
        die(127, "cannot run %s: docker is not installed for image %s" % (manifest["argv"][0], image))
    network = []
    if services:
        made = subprocess.run([docker, "network", "create", container(manifest)], stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if made.returncode:
            die(78, "could not create network %s: %s" % (container(manifest), made.stderr.strip()))
        network = ["--network", container(manifest)]
    for service in services:
        env = [arg for key, value in service["env"].items() for arg in ("-e", key + "=" + value)]
        ran = subprocess.run([docker, "run", "-d", "--name", service_name(manifest, service), "--memory", service["memory"],
                              "--memory-swap", service["memory"], *network, *env, service["image"]],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if ran.returncode:
            die(78, "service %s did not start: %s" % (service["name"], ran.stderr.strip()))
        network = ["--network", "container:" + service_name(manifest, services[0])]
    os.execv(docker, job_container_argv(jdir, manifest, docker, network))


def job_container_argv(jdir, manifest, docker, network):
    linux = os.path.join(ROOT, "linux")
    for sub in ("runtimes", "cache"):
        os.makedirs(os.path.join(linux, sub), exist_ok=True)
    tools = os.path.join(ROOT, "cache", "tools")
    return [docker, "run", "--rm", "--init", "--name", container(manifest), "--memory", "6g", "--memory-swap", "6g", *network,
            "--ulimit", "nofile={0}:{0}".format(manifest.get("nofile", 65536)),
            "-e", "HOME=" + os.path.expanduser("~"), "-e", "GIT_CONFIG_COUNT=1",
            "-e", "PLAYWRIGHT_BROWSERS_PATH=" + os.path.join(tools, "ms-playwright"),
            "-e", "pnpm_config_store_dir=" + os.path.join(tools, "pnpm-store"),  # pnpm 11+
            "-e", "npm_config_store_dir=" + os.path.join(tools, "pnpm-store"),  # older pinned pnpm
            "-e", "npm_config_cache=" + os.path.join(tools, "npm"),
            "-e", "GIT_CONFIG_KEY_0=safe.directory", "-e", "GIT_CONFIG_VALUE_0=*",
            "-v", jdir + ":" + jdir, "-v", os.path.join(linux, "runtimes") + ":" + os.path.join(ROOT, "runtimes") + ":ro",
            "-v", os.path.join(linux, "cache") + ":" + os.path.join(ROOT, "cache"),
            "-w", os.path.join(jdir, "work"), manifest["image"], "python3", os.path.join(jdir, "runner.py"), "execute", jdir]


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def cmd_start(jdir):
    manifest = read_json(os.path.join(jdir, "manifest.json")) or {}
    slots = host_slots(manifest.get("host_slots", 1))
    slot = take_host_slot(slots)
    if slot is None:
        die(BUSY, "busy: the host's heavy slot is taken or awaited")
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
    services = manifest.get("services") or []
    if services:
        docker = find_docker()
        info = subprocess.run([docker, "info", "--format", "{{.MemTotal}}"], capture_output=True, text=True) if docker else None
        need = (6 << 30) + sum(memory_bytes(s["memory"]) for s in services)
        if info and info.returncode == 0 and info.stdout.strip().isdigit() and need > int(info.stdout):
            die(13, "refused: the job and its services need %d MiB, docker has %d MiB" % (need >> 20, int(info.stdout) >> 20))
    bundle = os.path.join(jdir, "src.bundle")
    if not os.path.isfile(bundle) or sha256_file(bundle) != manifest.get("bundle_sha256"):
        die(10, "refused: source bundle digest mismatch")
    work = os.path.join(jdir, "work")
    cloned = git("clone", "-q", "--no-checkout", bundle, work)
    if cloned.returncode or git("-C", work, "checkout", "-q", "--detach", sha).returncode:
        die(10, "refused: could not check out %s: %s" % (sha, cloned.stderr.strip()))
    if git("-C", work, "rev-parse", "HEAD").stdout.strip() != sha:
        die(10, "refused: checkout is not %s" % sha)
    try:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "guard", jdir, str(slot)], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True,
                         pass_fds=(slot,))
    except OSError as error:
        die(10, "refused: could not launch supervisor: %s" % error)
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


def preparation_step(jdir, step):
    write_json(os.path.join(jdir, "preparation.json"), {"step": step})


def prepare_dependencies(work, manifest):
    jdir = os.path.dirname(work)
    preparation_step(jdir, "runtime")
    package_path = os.path.join(work, "package.json")
    package = read_json(package_path)
    if package is None:
        if os.path.exists(package_path):
            raise ValueError("invalid package.json")
        return
    if not isinstance(package, dict) or not isinstance(package.get("engines", {}), dict) or not isinstance(package.get("packageManager", ""), str):
        raise ValueError("invalid package.json runtime declarations")
    engines = package.get("engines", {})
    node_requirements = [engines["node"]] if "node" in engines else []
    nvmrc = os.path.join(work, ".nvmrc")
    if os.path.isfile(nvmrc):
        with open(nvmrc) as handle:
            node_requirements.append(handle.read().strip())
    node = select_runtime("node", node_requirements)
    locks = [name for name in ("pnpm-lock.yaml", "npm-shrinkwrap.json", "package-lock.json") if os.path.isfile(os.path.join(work, name))]
    if not locks:
        if any(package.get(field) for field in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies")):
            raise ValueError("package.json has no supported lockfile (pnpm-lock.yaml, npm-shrinkwrap.json or package-lock.json)")
        return
    if "pnpm-lock.yaml" in locks and len(locks) != 1:
        raise ValueError("ambiguous pnpm/npm lockfiles")
    manager = "pnpm" if locks[0] == "pnpm-lock.yaml" else "npm"
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
    preparation_step(jdir, "dependencies")
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
        # Playwright caches browser revisions per account, or under the container's
        # persistent cache; its installer only downloads revisions missing for this
        # checkout's installed version.
        command = ["pnpm", "exec", "playwright", "install"] if manager == "pnpm" else ["npm", "exec", "--no", "--", "playwright", "install"]
        preparation_step(jdir, "browsers")
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
    os.environ.update(manifest.get("env") or {})
    preparation_step(jdir, "services")
    for service in manifest.get("services") or []:
        end = time.monotonic() + 180
        while True:
            try:
                socket.create_connection(("127.0.0.1", service["port"]), 1).close()
                break
            except OSError:
                if time.monotonic() > end:
                    die(78, "service %s did not open port %d" % (service["name"], service["port"]))
                time.sleep(0.5)
    try:
        prepare_dependencies(os.path.join(jdir, "work"), manifest)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        die(78, "remote dependency/runtime preparation failed: %s" % error)
    preparation_step(jdir, "command")
    try:
        os.execvp(manifest["argv"][0], manifest["argv"])
    except OSError as error:
        die(127, "cannot run %s: %s" % (manifest["argv"][0], error))


def cmd_guard(jdir, slot):
    ready, notify = os.pipe()
    try:
        proc = subprocess.Popen([sys.executable, os.path.abspath(__file__), "supervise", jdir, str(slot), str(notify)],
                                start_new_session=True, pass_fds=(slot, notify))
    finally:
        os.close(notify)
    try:
        proc.wait()
        announced = os.read(ready, 4096)
        owner = json.loads(announced) if announced else None
        while owner and group_alive(owner):
            time.sleep(0.05)
    finally:
        os.close(ready)
        os.close(slot)


def cmd_supervise(jdir, slot, ready):
    os.set_inheritable(slot, False)
    manifest = read_json(os.path.join(jdir, "manifest.json"))
    work = os.path.join(jdir, "work")
    stops = []
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: stops.append(1))
    started_at, began = int(time.time()), time.monotonic()
    log = open(os.path.join(jdir, "run.log"), "wb")
    outcome, code = "exited", 127
    try:
        proc = subprocess.Popen(group_command(jdir, manifest) + [str(slot), str(ready), str(os.getpid()), proc_start(os.getpid())],
                                cwd=work, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True, pass_fds=(slot, ready))
    except OSError as error:
        log.write(("cannot run %s: %s\n" % (manifest["argv"][0], error)).encode())
        proc = None
    owner = {"supervisor_pid": os.getpid(), "supervisor_start": proc_start(os.getpid()),
             "group": proc.pid if proc else None, "group_start": proc_start(proc.pid) if proc else ""}
    os.close(ready)
    if proc is None:
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
            remove_container(manifest)
        code = proc.wait()
        code = 128 - code if code < 0 else code
        kill_group(owner)  # anything the command left running
        remove_container(manifest)
        if stops and outcome == "exited":
            outcome = "cancelled"
    log.close()
    step = (read_json(os.path.join(jdir, "preparation.json")) or {}).get("step", "container-start")
    if outcome in ("exited", "timeout") and code != 0 and step != "command":
        outcome = "prepare-failed"
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    artifact = os.path.join(jdir, "run.log")
    write_json(os.path.join(jdir, "result.json"), {
        "schema": SCHEMA, "id": manifest["id"],
        "sha": git("-C", work, "rev-parse", "HEAD").stdout.strip(),
        "tree": git("-C", work, "rev-parse", "HEAD^{tree}").stdout.strip(),
        "command_sha256": manifest["command_sha256"], "bundle_sha256": manifest["bundle_sha256"],
        "outcome": outcome, "preparation_step": step, "exit_code": code, "started_at": started_at, "ended_at": int(time.time()),
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
        remove_container(read_json(os.path.join(jdir, "manifest.json")) or {})
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
    remove_container(read_json(os.path.join(jdir, "manifest.json")) or {})
    shutil.rmtree(jdir, ignore_errors=True)


def main():
    if sys.argv[1:2] == ["busy"] and len(sys.argv) in (2, 3):
        cmd_busy(host_slots(sys.argv[2]) if len(sys.argv) == 3 else 1)
        return
    if len(sys.argv) < 3 or sys.argv[1] not in ("start", "guard", "supervise", "container", "execute", "status", "reconcile", "wait", "cancel", "cleanup"):
        die(2, "usage: fm-heavy-remote-runner.py busy [host-slots] | start|guard|supervise|container|execute|status|reconcile|wait|cancel|cleanup <jobdir> [seconds]")
    action, jdir = sys.argv[1], job_dir(sys.argv[2])
    if action in ("container", "execute") and len(sys.argv) == 7:
        slot, ready = int(sys.argv[3]), int(sys.argv[4])
        owner = {
            "supervisor_pid": int(sys.argv[5]), "supervisor_start": sys.argv[6],
            "group": os.getpid(), "group_start": proc_start(os.getpid())}
        write_json(os.path.join(jdir, "owner.json"), owner)
        os.write(ready, json.dumps(owner).encode())
        os.close(ready)
        os.close(slot)
    if action == "guard":
        cmd_guard(jdir, int(sys.argv[3]))
    elif action == "supervise":
        cmd_supervise(jdir, int(sys.argv[3]), int(sys.argv[4]))
    elif action == "status":
        print(status(jdir))
    elif action == "reconcile":
        print(reconcile_state(jdir))
    elif action == "wait":
        cmd_wait(jdir, float(sys.argv[3]) if len(sys.argv) > 3 else 0)
    else:
        {"start": cmd_start, "supervise": cmd_supervise, "container": cmd_container, "execute": cmd_execute, "cancel": cmd_cancel, "cleanup": cmd_cleanup}[action](jdir)


if __name__ == "__main__":
    main()
