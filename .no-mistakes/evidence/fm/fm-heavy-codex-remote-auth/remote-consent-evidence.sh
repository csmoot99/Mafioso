#!/usr/bin/env bash
set -eu
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot remote-consent-evidence)
EVIDENCE=/home/work/.no-mistakes/evidence/01M78EJVQ754X0B7H1ZZQDJF1D
for name in configured child-ship child-scout child-unapproved absent hostless; do
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  root_home="$home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  case "$name" in
    child-*)
      root_home="$case_dir/root-home"
      fm_test_spawn_home "$root_home" codex
      printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root_home" > "$home/.fm-secondmate-parent"
      ;;
  esac
  case "$name" in
    configured|child-ship|child-scout) printf 'host fm-mac\nproject 420usa\n' > "$root_home/config/heavy-remote" ;;
    hostless) printf 'project 420usa\n' > "$root_home/config/heavy-remote" ;;
  esac
  case "$name" in child-scout|child-unapproved) printf 'host child-host\nproject 420usa\n' > "$home/config/heavy-remote" ;; esac
  id="consent-$name"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  if [ "$name" = child-scout ]; then
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout > "$case_dir/spawn.out"
  else
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off > "$case_dir/spawn.out"
  fi
  fm_test_codex_launch_argv "$case_dir/launch.log" "$case_dir/argv"
  python3 - "$case_dir" "$EVIDENCE" "$name" "$home" "$root_home" <<'PY'
import pathlib, subprocess, sys
case, evidence, name, home, root = sys.argv[1:]
args = pathlib.Path(case, 'argv/args').read_bytes().split(b'\0')[:-1]
args = [x.decode() for x in args]
# The final positional argument is the generated launch brief. Use the real
# consumer's no-model renderer with the identical global flags.
p = subprocess.run(['codex', *args[:-1], 'debug', 'prompt-input', 'fm-probe'], cwd=pathlib.Path(case,'wt'), text=True, capture_output=True)
pathlib.Path(evidence, f'codex-{name}-prompt.txt').write_text(p.stdout + p.stderr)
assert p.returncode == 0, p.stderr
rendered = p.stdout
expected = name in ('configured','child-ship','child-scout')
assert ('The operator authorizes remote test execution' in rendered) == expected
if expected:
    for required in (f'FM_HOME={home}', f'{root}/config/heavy-remote', 'operator-controlled test host fm-mac', 'full Git bundle including repository history', 'does not authorize direct ssh, scp, rsync'):
        assert required in rendered, required
assert 'test host child-host' not in rendered
for required in ('`sandbox_mode` is `workspace-write`', '`approvals_reviewer` is `auto_review`', 'Network access is restricted.'):
    assert required in rendered, required
print(f'{name}: real Codex rendered consent={expected}; sandbox and automatic reviewer retained')
PY
done
