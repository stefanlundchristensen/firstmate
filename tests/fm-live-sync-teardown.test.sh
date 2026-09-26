#!/usr/bin/env bash
# Behavior tests for live-sync teardown lock release and lingering process safety.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-sync-teardown)

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
    "$fakebin" "$vault" "$tasktmp" "$case_dir/state/live-sync-locks"
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
  printf 'project=vault\nroot=%s\npolicy=%s\nscope=file\t%s/Note.md\tNote.md\n' \
    "$vault" "$policy" "$vault" > "$case_dir/state/live-sync-locks/task-x1.lock"
  printf '%s\n' "$case_dir"
}

run_live_teardown() {  # <case-dir>
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
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

test_uncertain_live_root_process_retains_lock() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case uncertain 0)
  vault="$case_dir/vault"
  pid=$(start_detached_in_vault "$vault")
  wait_for_lsof_cwd "$pid" "$vault" || { kill "$pid" 2>/dev/null || true; fail "uncertain live-root process never appeared in lsof"; }
  run_live_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 1 "$rc" "uncertain live-root process should refuse teardown"
  assert_present "$case_dir/state/task-x1.meta" "uncertain live-root process removed task metadata"
  assert_present "$case_dir/state/live-sync-locks/task-x1.lock" "uncertain live-root process released the live-sync lock"
  assert_grep "unattributed process" "$case_dir/stderr" "uncertain live-root refusal did not name unattributed process ownership"
  pass "live-sync teardown retains locks for uncertain live-root processes"
}

test_owned_live_root_process_is_stopped_before_lock_release() {
  local case_dir vault pid rc=0
  case_dir=$(make_live_case owned 0)
  vault="$case_dir/vault"
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
  assert_absent "$case_dir/state/live-sync-locks/task-x1.lock" "owned live-root process left live-sync lock after cleanup"
  assert_grep "reaping leaked live-sync process" "$case_dir/stderr" "owned live-root cleanup did not report process reaping"
  pass "live-sync teardown stops owned live-root processes before releasing locks"
}

test_uncertain_live_root_process_retains_lock
test_owned_live_root_process_is_stopped_before_lock_release
