#!/usr/bin/env bash
# Behavior tests for live-sync shutdown proofs and task-record retirement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-sync-teardown)
# Keep unrelated maintenance out of the private lifecycle fixtures.
FIXTURE_CODE="$TMP_ROOT/code"
mkdir -p "$FIXTURE_CODE"
cp -R "$ROOT/bin" "$FIXTURE_CODE/bin"
for fixture_hook in fm-guard.sh fm-remote-job-reap-orphans.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE_CODE/bin/$fixture_hook"
done
TEARDOWN="$FIXTURE_CODE/bin/fm-teardown.sh"

if ! command -v lsof >/dev/null 2>&1; then
  echo "skip: lsof unavailable; live-sync teardown process tests require cwd inspection"
  exit 0
fi

make_live_case() {  # <name> <tmux-pane-pid>
  local name=$1 pane_pid=${2:-0} case_dir fakebin vault tasktmp policy
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  vault="$case_dir/vault"
  tasktmp="$case_dir/tasktmp"
  mkdir -p "$case_dir/home" "$case_dir/state" "$case_dir/data" "$case_dir/config" \
    "$fakebin" "$vault" "$tasktmp"
  touch "$case_dir/state/.last-watcher-beat"
  printf 'note\n' > "$vault/Note.md"
  policy="$vault/.firstmate-live-sync-policy"
  cat > "$policy" <<'EOF'
allow .
protect .firstmate-live-sync-policy
EOF
  cat > "$fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$pane_pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fakebin/tmux"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$vault" \
    "project=vault" \
    "kind=ship" \
    "mode=live-sync" \
    "tasktmp=$tasktmp" \
    "backend=tmux" \
    "spawn_gen=live-sync-teardown-test" \
    "live_sync_root=$vault" \
    "live_sync_policy=$policy" \
    $'live_sync_scope=file\tNote.md'
  printf '%s\n' "$case_dir"
}

configure_herdr_case() {  # <case-dir> <pgid>
  local case_dir=$1 pgid=$2 vault tasktmp policy
  vault="$case_dir/vault"
  tasktmp="$case_dir/tasktmp"
  policy="$vault/.firstmate-live-sync-policy"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:w1:p1" \
    "endpoint_task_id=task-x1" \
    "worktree=$vault" \
    "project=vault" \
    "kind=ship" \
    "mode=live-sync" \
    "tasktmp=$tasktmp" \
    "backend=herdr" \
    "herdr_session=firstmate" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=t1" \
    "herdr_pane_id=w1:p1" \
    "spawn_gen=live-sync-teardown-test" \
    "live_sync_root=$vault" \
    "live_sync_policy=$policy" \
    $'live_sync_scope=file\tNote.md'
  cat > "$case_dir/fakebin/herdr" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then
  printf '%s\n' '{"client":{"protocol":22},"server":{"running":true,"compatible":true,"protocol":22}}'
  exit 0
fi
if [ "\${1:-}" = session ] && [ "\${2:-}" = list ]; then
  printf '%s\n' '{"sessions":[{"name":"firstmate","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
  exit 0
fi
if [ "\${1:-}" = pane ] && [ "\${2:-}" = process-info ]; then
  printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","foreground_process_group_id":$pgid,"shell_pid":$pgid,"foreground_processes":[]}}}'
  exit 0
fi
if [ "\${1:-}" = pane ] && [ "\${2:-}" = get ]; then
  printf '%s\n' '{"error":{"code":"pane_not_found"}}'
  exit 1
fi
if [ "\${1:-}" = pane ] && [ "\${2:-}" = close ]; then
  exit 0
fi
printf '%s\n' '{"result":{}}'
EOF
  chmod +x "$case_dir/fakebin/herdr"
}

run_live_teardown() {  # <case-dir>
  local case_dir=$1 proc_root
  if [ -n "${FM_LIVE_SYNC_PROC_ROOT_OVERRIDE:-}" ]; then
    proc_root=$FM_LIVE_SYNC_PROC_ROOT_OVERRIDE
  else
    proc_root=$case_dir/proc
    mkdir -p "$proc_root"
  fi
  FM_ROOT_OVERRIDE="$FIXTURE_CODE" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_LIVE_SYNC_PROC_ROOT_OVERRIDE="$proc_root" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1
}

start_detached_in_vault() {  # <vault>
  ( cd "$1" && python3 -c 'import time; time.sleep(300)' ) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

start_owned_group_in_vault() {  # <vault>
  python3 -c 'import os, sys, time; os.setsid(); os.chdir(sys.argv[1]); time.sleep(300)' "$1" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

start_owned_group_writer_outside_vault() {  # <vault>
  python3 -c 'import os, sys, time; os.setsid(); os.chdir("/tmp"); path=os.path.join(sys.argv[1], "Note.md"); open(path, "a").write("started\\n"); time.sleep(300)' "$1" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

start_endpoint_with_detached_writer() {  # <vault> <pid-file>
  python3 -c 'import os, sys, time; os.setsid(); child=os.fork();
if child == 0:
    os.setsid(); os.chdir("/tmp"); open(os.path.join(sys.argv[1], "Note.md"), "a").write("detached\\n"); time.sleep(300)
else:
    open(sys.argv[2], "w").write(str(child)); time.sleep(300)' "$1" "$2" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

start_endpoint_with_trap_spawner() {  # <vault> <child-pid-file> <spawned-pid-file>
  python3 -c 'import os, signal, sys, time; marker="LIVE_SYNC_ROOT"; os.setsid(); child=os.fork();
if child == 0:
    def term(_signum, _frame):
        spawned=os.fork()
        if spawned == 0:
            os.setsid(); os.chdir("/tmp"); open(os.path.join(sys.argv[1], "Note.md"), "a").write("spawned\\n"); time.sleep(300)
        open(sys.argv[3], "w").write(str(spawned)); sys.exit(0)
    signal.signal(signal.SIGTERM, term); time.sleep(300)
else:
    open(sys.argv[2], "w").write(str(child)); time.sleep(300)' "$1" "$2" "$3" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

start_endpoint_with_daemonized_writer() {  # <vault> <writer-pid-file>
  FM_TASK_ID=task-x1 VAULT="$1" python3 -c 'import os, sys, time; os.setsid(); child=os.fork();
if child == 0:
    os.setsid(); grandchild=os.fork()
    if grandchild == 0:
        os.chdir("/tmp"); open(os.path.join(os.environ["VAULT"], "Note.md"), "a").write("daemonized\\n"); time.sleep(300)
    else:
        open(sys.argv[1], "w").write(str(grandchild)); sys.exit(0)
else:
    os.waitpid(child, 0); time.sleep(300)' "$2" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

wait_for_file() {  # <file>
  local file=$1 i=0
  while [ "$i" -lt 50 ]; do
    [ -s "$file" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_pid() {  # <pid>
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

pid_is_live_non_zombie() {  # <pid>
  local stat
  kill -0 "$1" 2>/dev/null || return 1
  stat=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  stat=$(printf '%s' "$stat" | tr -d '[:space:]')
  case "$stat" in Z*) return 1 ;; *) return 0 ;; esac
}

wait_for_lsof_cwd() {  # <pid> <dir>
  local pid=$1 dir=$2 i=0 out
  while [ "$i" -lt 50 ]; do
    out=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null || true)
    printf '%s\n' "$out" | grep -Fxq "n$dir" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_uncertain_live_root_process_retains_record() {
  local case_dir vault pid endpoint_pid rc=0
  case_dir=$(make_live_case uncertain 0)
  vault="$case_dir/vault"
  endpoint_pid=$(start_owned_group_writer_outside_vault "$vault")
  wait_for_pid "$endpoint_pid" || { kill "$endpoint_pid" 2>/dev/null || true; fail "endpoint process never started"; }
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$endpoint_pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  pid=$(start_detached_in_vault "$vault")
  wait_for_lsof_cwd "$pid" "$vault" || { kill "$pid" "$endpoint_pid" 2>/dev/null || true; fail "uncertain live-root process never appeared in lsof"; }
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill "$pid" "$endpoint_pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$endpoint_pid" 2>/dev/null || true
  expect_code 1 "$rc" "uncertain live-root process should refuse teardown"
  assert_present "$case_dir/state/task-x1.meta" "uncertain live-root process removed task metadata"
  assert_grep "unattributed process" "$case_dir/stderr" "uncertain live-root refusal did not name unattributed process ownership"
  pass "live-sync teardown retains the record for uncertain live-root processes"
}

test_owned_live_root_process_is_stopped_before_record_removal() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case owned 0)
  vault="$case_dir/vault"
  mkdir -p "$case_dir/state/live-sync-locks"
  printf 'historical reservation evidence\n' > "$case_dir/state/live-sync-locks/task-x1.lock"
  cp "$case_dir/state/live-sync-locks/task-x1.lock" "$case_dir/historical-before"
  pid=$(start_owned_group_in_vault "$vault")
  wait_for_lsof_cwd "$pid" "$vault" || { kill "$pid" 2>/dev/null || true; fail "owned live-root process never appeared in lsof"; }
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 0 ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "owned live-root process teardown failed"; }
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "owned live-root process survived teardown"
  fi
  assert_absent "$case_dir/state/task-x1.meta" "owned live-root process left task metadata after cleanup"
  cmp -s "$case_dir/historical-before" "$case_dir/state/live-sync-locks/task-x1.lock" \
    || fail "ordinary cleanup touched inert historical reservation evidence"
  assert_grep "reaping leaked live-sync process" "$case_dir/stderr" "owned live-root cleanup did not report process reaping"
  pass "live-sync teardown stops owned writers before retiring the record and leaves historical reservations inert"
}

test_owned_endpoint_writer_outside_vault_is_stopped_before_record_removal() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case owned-outside 0)
  vault="$case_dir/vault"
  pid=$(start_owned_group_writer_outside_vault "$vault")
  wait_for_pid "$pid" || { kill "$pid" 2>/dev/null || true; fail "owned outside-vault writer never started"; }
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 0 ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "owned outside-vault writer teardown failed"; }
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "owned outside-vault writer survived teardown"
  fi
  assert_absent "$case_dir/state/task-x1.meta" "owned outside-vault writer left task metadata after cleanup"
  assert_grep "reaping leaked live-sync process" "$case_dir/stderr" "owned outside-vault writer cleanup did not report process reaping"
  pass "live-sync teardown stops owned endpoint writers outside the vault cwd before retiring the record"
}

test_detached_endpoint_descendant_writer_is_stopped_before_record_removal() {
  local case_dir vault pidfile endpoint_pid writer_pid rc=0
  case_dir=$(make_live_case detached-descendant 0)
  vault="$case_dir/vault"
  pidfile="$case_dir/detached-writer.pid"
  endpoint_pid=$(start_endpoint_with_detached_writer "$vault" "$pidfile")
  wait_for_pid "$endpoint_pid" || { kill "$endpoint_pid" 2>/dev/null || true; fail "endpoint process never started"; }
  wait_for_file "$pidfile" || { kill "$endpoint_pid" 2>/dev/null || true; fail "detached writer pid was not recorded"; }
  writer_pid=$(<"$pidfile")
  wait_for_pid "$writer_pid" || { kill "$endpoint_pid" "$writer_pid" 2>/dev/null || true; fail "detached writer never started"; }
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$endpoint_pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 0 ] || { kill "$endpoint_pid" "$writer_pid" 2>/dev/null || true; wait "$endpoint_pid" 2>/dev/null || true; wait "$writer_pid" 2>/dev/null || true; fail "detached descendant writer teardown failed"; }
  if pid_is_live_non_zombie "$writer_pid"; then
    kill "$endpoint_pid" "$writer_pid" 2>/dev/null || true
    wait "$endpoint_pid" 2>/dev/null || true
    wait "$writer_pid" 2>/dev/null || true
    fail "detached descendant writer survived teardown"
  fi
  assert_absent "$case_dir/state/task-x1.meta" "detached descendant writer left task metadata after cleanup"
  assert_grep "captured live-sync descendant" "$case_dir/stderr" "detached descendant cleanup did not report captured descendant reaping"
  pass "live-sync teardown stops detached endpoint descendants before retiring the record"
}

test_trap_spawned_detached_writer_retains_record() {
  local case_dir vault child_pidfile spawned_pidfile endpoint_pid child_pid spawned_pid rc=0
  case_dir=$(make_live_case trap-spawner 0)
  vault="$case_dir/vault"
  child_pidfile="$case_dir/trap-child.pid"
  spawned_pidfile="$case_dir/spawned-writer.pid"
  endpoint_pid=$(start_endpoint_with_trap_spawner "$vault" "$child_pidfile" "$spawned_pidfile")
  wait_for_pid "$endpoint_pid" || { kill "$endpoint_pid" 2>/dev/null || true; fail "endpoint process never started"; }
  wait_for_file "$child_pidfile" || { kill "$endpoint_pid" 2>/dev/null || true; fail "trap child pid was not recorded"; }
  child_pid=$(<"$child_pidfile")
  wait_for_pid "$child_pid" || { kill "$endpoint_pid" "$child_pid" 2>/dev/null || true; fail "trap child never started"; }
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$endpoint_pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "trap-spawned writer should retain the task record"
  wait_for_file "$spawned_pidfile" || { kill "$endpoint_pid" "$child_pid" 2>/dev/null || true; fail "trap-spawned writer pid was not recorded"; }
  spawned_pid=$(<"$spawned_pidfile")
  if ! kill -0 "$spawned_pid" 2>/dev/null; then
    wait "$spawned_pid" 2>/dev/null || true
    fail "trap-spawned detached writer was unexpectedly killed"
  fi
  kill -KILL "$endpoint_pid" "$child_pid" "$spawned_pid" 2>/dev/null || true
  wait "$endpoint_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
  wait "$spawned_pid" 2>/dev/null || true
  assert_present "$case_dir/state/task-x1.meta" "trap-spawned writer removed task metadata"
  assert_grep "possible detached task-owned writer" "$case_dir/stderr" "trap-spawned writer refusal did not name detached writer marker"
  pass "live-sync teardown retains the record for trap-spawned detached writers"
}

test_daemonized_writer_retains_record_without_current_descendants() {
  local case_dir vault pidfile endpoint_pid writer_pid proc_root rc=0
  case_dir=$(make_live_case daemonized-writer 0)
  vault="$case_dir/vault"
  pidfile="$case_dir/daemonized-writer.pid"
  endpoint_pid=$(start_endpoint_with_daemonized_writer "$vault" "$pidfile")
  wait_for_pid "$endpoint_pid" || { kill "$endpoint_pid" 2>/dev/null || true; fail "daemonizing endpoint never started"; }
  wait_for_file "$pidfile" || { kill "$endpoint_pid" 2>/dev/null || true; fail "daemonized writer pid was not recorded"; }
  writer_pid=$(<"$pidfile")
  wait_for_pid "$writer_pid" || { kill "$endpoint_pid" "$writer_pid" 2>/dev/null || true; fail "daemonized writer never started"; }
  proc_root="$case_dir/proc"
  mkdir -p "$proc_root/$writer_pid"
  printf 'FM_TASK_ID=task-x1\0VAULT=%s\0' "$vault" > "$proc_root/$writer_pid/environ"
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$endpoint_pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  FM_LIVE_SYNC_PROC_ROOT_OVERRIDE="$proc_root" run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "daemonized writer should retain the task record"
  if ! kill -0 "$writer_pid" 2>/dev/null; then
    wait "$writer_pid" 2>/dev/null || true
    fail "daemonized writer was unexpectedly killed"
  fi
  kill -KILL "$endpoint_pid" "$writer_pid" 2>/dev/null || true
  wait "$endpoint_pid" 2>/dev/null || true
  wait "$writer_pid" 2>/dev/null || true
  assert_present "$case_dir/state/task-x1.meta" "daemonized writer removed task metadata"
  assert_grep "possible detached task-owned writer" "$case_dir/stderr" "daemonized writer refusal did not name detached writer marker"
  pass "live-sync teardown retains the record for daemonized detached writers"
}

test_missing_env_ownership_probe_retains_record() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case missing-env-proof 0)
  vault="$case_dir/vault"
  pid=$(start_owned_group_writer_outside_vault "$vault")
  wait_for_pid "$pid" || { kill "$pid" 2>/dev/null || true; fail "missing-env-proof endpoint writer never started"; }
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  FM_LIVE_SYNC_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_LIVE_SYNC_PS_ENV_PROOF_OVERRIDE=0 run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "missing environment ownership proof should retain the task record"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_present "$case_dir/state/task-x1.meta" "missing environment proof removed task metadata"
  assert_grep "environment ownership cannot be inspected" "$case_dir/stderr" "missing environment proof refusal did not name unavailable proof"
  pass "live-sync teardown retains the record when environment ownership cannot be inspected"
}

test_ps_environment_probe_retires_record_without_procfs() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case ps-env-proof 0)
  vault="$case_dir/vault"
  pid=$(start_owned_group_writer_outside_vault "$vault")
  wait_for_pid "$pid" || { kill "$pid" 2>/dev/null || true; fail "ps-env-proof endpoint writer never started"; }
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  FM_LIVE_SYNC_PROC_ROOT_OVERRIDE="$case_dir/no-proc" run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 0 ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "ps environment proof teardown failed"; }
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "ps environment proof endpoint writer survived teardown"
  fi
  assert_absent "$case_dir/state/task-x1.meta" "ps environment proof left task metadata after cleanup"
  pass "live-sync teardown uses ps environment proof when procfs is absent"
}

test_missing_live_root_retains_record_after_endpoint_reap() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case missing-root 0)
  vault="$case_dir/vault"
  pid=$(start_owned_group_writer_outside_vault "$vault")
  wait_for_pid "$pid" || { kill "$pid" 2>/dev/null || true; fail "missing-root endpoint writer never started"; }
  mv "$vault" "$vault.gone" || { kill "$pid" 2>/dev/null || true; fail "could not make live root unavailable"; }
  rm -f "$case_dir/fakebin/tmux"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%s\n' '$pid' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$case_dir/fakebin/tmux"
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "missing live root should retain the task record"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_present "$case_dir/state/task-x1.meta" "missing live root removed task metadata"
  assert_grep "REFUSED: live-sync task" "$case_dir/stderr" "missing live root did not refuse live-sync cleanup"
  pass "live-sync teardown retains the record when the live root is unavailable"
}

test_herdr_endpoint_writer_outside_vault_is_stopped_before_record_removal() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case herdr-owned 0)
  vault="$case_dir/vault"
  pid=$(start_owned_group_writer_outside_vault "$vault")
  wait_for_pid "$pid" || { kill "$pid" 2>/dev/null || true; fail "herdr outside-vault writer never started"; }
  configure_herdr_case "$case_dir" "$pid"
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 0 ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "herdr outside-vault writer teardown failed"; }
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "herdr outside-vault writer survived teardown"
  fi
  assert_absent "$case_dir/state/task-x1.meta" "herdr outside-vault writer left task metadata after cleanup"
  assert_grep "reaping leaked live-sync process" "$case_dir/stderr" "herdr outside-vault writer cleanup did not report process reaping"
  pass "live-sync teardown stops Herdr-owned endpoint writers before retiring the record"
}

test_missing_endpoint_ownership_retains_record_without_killing_writer() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case missing-endpoint 0)
  vault="$case_dir/vault"
  pid=$(start_owned_group_writer_outside_vault "$vault")
  wait_for_pid "$pid" || { kill "$pid" 2>/dev/null || true; fail "outside-vault writer never started"; }
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "missing endpoint ownership should refuse teardown"
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "missing endpoint ownership path killed an unproven writer"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_present "$case_dir/state/task-x1.meta" "missing endpoint ownership removed task metadata"
  assert_grep "ownership was not captured" "$case_dir/stderr" "missing endpoint ownership refusal did not name missing proof"
  pass "live-sync teardown retains the record when endpoint ownership is missing"
}

test_uncertain_live_root_process_retains_record
test_owned_live_root_process_is_stopped_before_record_removal
test_owned_endpoint_writer_outside_vault_is_stopped_before_record_removal
test_detached_endpoint_descendant_writer_is_stopped_before_record_removal
test_trap_spawned_detached_writer_retains_record
test_daemonized_writer_retains_record_without_current_descendants
test_missing_env_ownership_probe_retains_record
test_ps_environment_probe_retires_record_without_procfs
test_missing_live_root_retains_record_after_endpoint_reap
test_herdr_endpoint_writer_outside_vault_is_stopped_before_record_removal
test_missing_endpoint_ownership_retains_record_without_killing_writer
