#!/usr/bin/env bash
# Behavior tests for Firstmate live-sync project delivery: synthetic vault roots
# only, never the real vault.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-live-sync-lib.sh
. "$ROOT/bin/fm-live-sync-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-sync)
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
LIVE_SYNC="$ROOT/bin/fm-live-sync.sh"

make_vault() {  # <name>
  local dir=$1 root policy
  root="$TMP_ROOT/$dir/vault"
  mkdir -p "$root/Notes" "$root/Config" "$root/Other"
  printf 'alpha\n' > "$root/Notes/a.md"
  printf 'beta\n' > "$root/Notes/b.md"
  printf 'core\n' > "$root/Config/core.md"
  ln -s Notes "$root/AliasNotes"
  policy="$root/.firstmate-live-sync-policy"
  cat > "$policy" <<'EOF'
allow Notes
allow Config
protect Config/core.md
EOF
  printf '%s\n' "$root"
}

canonical_path() { perl -MCwd=abs_path -e 'print abs_path($ARGV[0])' -- "$1"; }

assert_live_sync_refuses() {  # <label> <root> <policy> <scope...>
  local label=$1 root=$2 policy=$3 out rc
  shift 3
  out=$(fm_live_sync_validate_scopes "$root" "$policy" "$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label unexpectedly passed"
  printf '%s\n' "$out"
}

test_policy_validation_and_canonicalization() {
  local root policy out
  root=$(make_vault policy)
  policy="$root/.firstmate-live-sync-policy"
  root=$(fm_live_sync_canonical_root "$root") || fail "root did not canonicalize"
  policy=$(fm_live_sync_canonical_policy "$root" "$policy") || fail "policy did not canonicalize"

  fm_live_sync_validate_scopes "$root" "$policy" Notes/a.md || fail "ordinary note scope should pass"
  assert_equals Notes/a.md "${FM_LIVE_SYNC_SCOPE_RELS[0]}" "ordinary note scope rel canonicalization drifted"
  assert_equals file "${FM_LIVE_SYNC_SCOPE_KINDS[0]}" "ordinary note kind drifted"

  fm_live_sync_validate_scopes "$root" "$policy" AliasNotes/a.md || fail "symlink alias to an allowed note should pass"
  assert_equals Notes/a.md "${FM_LIVE_SYNC_SCOPE_RELS[0]}" "symlink alias did not collapse to canonical note path"

  out=$(assert_live_sync_refuses traversal "$root" "$policy" ../outside.md)
  assert_contains "$out" "does not resolve inside" "traversal refusal did not name the outside-root reason"

  out=$(assert_live_sync_refuses protected "$root" "$policy" Config/core.md)
  assert_contains "$out" "overlaps protected path Config/core.md" "protected core-file refusal did not name the protected path"

  out=$(assert_live_sync_refuses unclassified "$root" "$policy" Other/new.md)
  assert_contains "$out" "is not allowed" "unclassified scope refusal did not name the policy classification"

  out=$(assert_live_sync_refuses overlap "$root" "$policy" Notes Notes/a.md)
  assert_contains "$out" "declared scopes overlap each other" "overlapping declared scopes were not refused"

  pass "fm-live-sync-lib: canonicalization, symlink aliases, traversal, protection, classification, and self-overlap checks"
}

test_overlapping_live_spawns_ignore_historical_reservations() {
  local root home fakebin id out rc
  root=$(make_vault overlap)
  home="$TMP_ROOT/overlap/home"
  fakebin="$TMP_ROOT/overlap/bin"
  mkdir -p "$home/data" "$home/state/live-sync-locks" "$home/config" "$fakebin"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '%s\n' "- vault [live-sync path=$root policy=.firstmate-live-sync-policy] - synthetic vault" > "$home/data/projects.md"
  printf 'project=vault\nroot=%s\npolicy=%s/.firstmate-live-sync-policy\nscope=file\t%s/Notes/a.md\tNotes/a.md\n' \
    "$root" "$root" "$root" > "$home/state/live-sync-locks/finished.lock"
  cp "$home/state/live-sync-locks/finished.lock" "$TMP_ROOT/overlap/historical-before"
  write_fake_tmux "$fakebin/tmux"
  for id in live-overlap-a live-overlap-b; do
    FM_HOME="$home" "$BRIEF" "$id" vault --mode live-sync --live-scope Notes/a.md >/dev/null \
      || fail "cannot scaffold overlapping fixture $id"
    fill_brief_subsections "$home/data/$id/brief.md"
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" vault 'bash -lc true' --mode live-sync --yolo off --live-scope Notes/a.md 2>&1)
    rc=$?
    expect_code 0 "$rc" "overlapping live spawn failed: $out"
    assert_present "$home/state/$id.meta" "overlapping spawn did not publish its worker record"
    assert_grep $'live_sync_scope=file\tNotes/a.md' "$home/state/$id.meta" "spawn lost the policy-validated write scope"
    assert_absent "$home/state/live-sync-locks/$id.lock" "spawn created a new file reservation"
  done
  cmp -s "$TMP_ROOT/overlap/historical-before" "$home/state/live-sync-locks/finished.lock" \
    || fail "spawn changed historical reservation evidence"
  assert_absent "$home/state/.live-sync-locks.lock" "spawn created a file-reservation index lock"
  FM_HOME="$home" "$BRIEF" live-denied vault --mode live-sync --live-scope Notes/a.md >/dev/null \
    || fail "cannot scaffold protected-path fixture"
  fill_brief_subsections "$home/data/live-denied/brief.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" live-denied vault 'bash -lc true' --mode live-sync --yolo off --live-scope Config/core.md 2>&1)
  rc=$?
  expect_code 1 "$rc" 'reservation removal must not bypass forbidden-path policy'
  assert_contains "$out" 'overlaps protected path Config/core.md' 'protected-path spawn did not report the policy refusal'
  assert_absent "$home/state/live-denied.meta" 'protected-path spawn published a worker'
  pass 'fm-spawn: overlapping live scopes launch without reservations; historical evidence stays inert and protected paths still refuse'
}

test_project_mode_live_sync_registry() {
  local root home out rc
  root=$(make_vault registry)
  home="$TMP_ROOT/registry/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<EOF
- vault [live-sync path=$root policy=.firstmate-live-sync-policy] - synthetic vault
- yolo-vault [live-sync +yolo path=$root policy=.firstmate-live-sync-policy] - invalid yolo vault
- forge-vault [live-sync forge=gerrit path=$root policy=.firstmate-live-sync-policy] - invalid forge vault
EOF

  out=$(FM_HOME="$home" "$PROJECT_MODE" vault) || fail "live-sync registry row did not resolve"
  assert_equals "live-sync off" "$out" "live-sync default posture output drifted"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --live-root vault) || fail "live root query failed"
  assert_equals "$root" "$out" "live root query returned the wrong root token"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --live-policy vault) || fail "live policy query failed"
  assert_equals ".firstmate-live-sync-policy" "$out" "live policy query returned the wrong policy token"
  out=$(FM_HOME="$home" "$LIVE_SYNC" info vault) || fail 'live-sync info failed without reservation wiring'
  assert_contains "$out" "root: $(canonical_path "$root")" 'live-sync info returned the wrong canonical root'
  out=$(FM_HOME="$home" "$LIVE_SYNC" check vault --scope Notes/a.md) || fail 'live-sync policy check rejected an allowed scope'
  assert_contains "$out" 'ok: live-sync scopes are allowed for vault' 'live-sync check lost its policy-validation result'
  out=$(FM_HOME="$home" "$LIVE_SYNC" check vault --scope Config/core.md 2>&1)
  rc=$?
  expect_code 1 "$rc" 'live-sync CLI must retain forbidden-path policy'
  assert_contains "$out" 'overlaps protected path Config/core.md' 'live-sync CLI did not report the protected-path refusal'

  out=$(FM_HOME="$home" "$PROJECT_MODE" yolo-vault 2>&1)
  rc=$?
  expect_code 3 "$rc" "live-sync +yolo registry refusal"
  assert_contains "$out" "live-sync has no merge step" "live-sync +yolo refusal did not name the merge-authority mismatch"

  out=$(FM_HOME="$home" "$PROJECT_MODE" forge-vault 2>&1)
  rc=$?
  expect_code 3 "$rc" "live-sync forge registry refusal"
  assert_contains "$out" "live-sync publishes nothing" "live-sync forge refusal did not name the publish mismatch"

  out=$(FM_HOME="$home" "$LIVE_SYNC" acquire live-manual vault --scope Notes/a.md 2>&1)
  rc=$?
  expect_code 2 "$rc" "manual live-sync acquire refusal"
  assert_contains "$out" "unknown command acquire" "manual acquire refusal did not name the removed command"
  assert_absent "$home/state/live-sync-locks/live-manual.lock" "unsupported acquire created a file reservation"

  mkdir -p "$home/state"
  mkdir -p "$home/state/live-sync-locks"
  printf 'historical reservation evidence\n' > "$home/state/live-sync-locks/live-manual.lock"
  out=$(FM_HOME="$home" "$LIVE_SYNC" release live-manual 2>&1)
  rc=$?
  expect_code 2 "$rc" "manual live-sync release refusal"
  assert_contains "$out" "unknown command release" "manual release refusal did not name the removed command"
  assert_present "$home/state/live-sync-locks/live-manual.lock" "unsupported release deleted historical reservation evidence"

  pass "fm-project-mode/fm-live-sync: registry queries, invalid token refusals, and no historical reservation mutation"
}

fill_brief_subsections() {  # <file>
  local file=$1 content
  content=$(<"$file")
  content=${content//'{TASK}'/Edit the synthetic note.}
  content=${content//'{FIRSTMATE_SPEC}'/Stay inside Notes\/a.md.}
  printf '%s\n' "$content" > "$file"
}

write_fake_tmux() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  has-session|new-session|set-window-option|send-keys) exit 0 ;;
  list-windows) exit 0 ;;
  new-window) printf '%%1\n'; exit 0 ;;
  display-message)
    case "$*" in
      *'#S'*) printf 'firstmate\n' ;;
      *'#{pane_id}'*) printf '%%pane\n' ;;
      *'#{pane_current_path}'*) printf '%s\n' "$PWD" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$1"
}

test_brief_and_spawn_live_sync_scope_contract() {
  local root home fakebin out rc brief lockfile
  root=$(make_vault spawn)
  home="$TMP_ROOT/spawn/home"
  fakebin="$TMP_ROOT/spawn/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$fakebin"
  cat > "$home/data/projects.md" <<EOF
- vault [live-sync path=$root policy=.firstmate-live-sync-policy] - synthetic vault
EOF
  printf '#!/bin/sh\necho fake tmux backend >&2\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"

  FM_HOME="$home" "$BRIEF" live-a vault --mode live-sync --live-scope Notes/a.md >/dev/null
  brief="$home/data/live-a/brief.md"
  fill_brief_subsections "$brief"
  assert_grep "Delivery contract: mode=live-sync" "$brief" "live-sync brief did not record its delivery mode"
  assert_grep "Live sync write scopes:" "$brief" "live-sync brief did not record a write-scope list"
  assert_grep "- Notes/a.md" "$brief" "live-sync brief did not record the requested scope"
  assert_no_grep "Ship branch:" "$brief" "live-sync brief should not record a ship branch"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
      "$SPAWN" live-a vault "bash -lc true" --mode live-sync --yolo off --live-scope Notes/a.md 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "spawn should have reached the fake tmux backend and failed"
  assert_contains "$out" "tmux" "spawn did not reach the backend after validating the live-sync contract"
  lockfile="$home/state/live-sync-locks/live-a.lock"
  assert_absent "$lockfile" "failed fresh live-sync spawn created a file reservation"

  out=$(FM_HOME="$home" "$BRIEF" live-b vault --mode live-sync --live-scope Notes/b.md --branch-prefix fm/ 2>&1)
  rc=$?
  expect_code 1 "$rc" "live-sync brief branch-prefix refusal"
  assert_contains "$out" "creates no branch" "live-sync branch-prefix refusal did not name the no-branch contract"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
      "$SPAWN" live-a vault "bash -lc true" --mode live-sync --yolo on --live-scope Notes/a.md 2>&1)
  rc=$?
  expect_code 1 "$rc" "live-sync spawn yolo refusal"
  assert_contains "$out" "has no merge step" "live-sync yolo refusal did not name the no-merge contract"

  pass "fm-brief/fm-spawn: live-sync records scopes, refuses branch/yolo drift, and creates no reservations on failure"
}

test_live_sync_backlog_failure_preserves_record() {
  local root home fakebin real_tasks out rc brief
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the live-sync backlog failure regression cannot run"
    return
  }
  root=$(make_vault backlog-failure)
  home="$TMP_ROOT/backlog-failure/home"
  fakebin="$TMP_ROOT/backlog-failure/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$fakebin"
  cat > "$home/data/projects.md" <<EOF
- vault [live-sync path=$root policy=.firstmate-live-sync-policy] - synthetic vault
EOF
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  tasks-axi add live-c 'live sync regression task' --kind ship --file "$home/data/backlog.md" >/dev/null || {
    pass "skipped: tasks-axi could not seed the live-sync backlog regression"
    return
  }
  write_fake_tmux "$fakebin/tmux"
  real_tasks=$(command -v tasks-axi)
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: synthetic start failure' >&2
  exit 1
fi
exec "$real_tasks" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"

  FM_HOME="$home" "$BRIEF" live-c vault --mode live-sync --live-scope Notes/a.md >/dev/null
  brief="$home/data/live-c/brief.md"
  fill_brief_subsections "$brief"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
      "$SPAWN" live-c vault "bash -lc true" --mode live-sync --yolo off --live-scope Notes/a.md 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "spawn should fail when the final backlog start fails"
  assert_contains "$out" "task record was preserved" "live-sync backlog failure did not report supervised preservation"
  assert_present "$home/state/live-c.meta" "live-sync backlog failure removed the task record"
  assert_absent "$home/state/live-sync-locks/live-c.lock" "live-sync backlog failure created a file reservation"

  pass "fm-spawn: live-sync post-launch backlog failures keep teardown-owned state"
}

test_policy_validation_and_canonicalization
test_overlapping_live_spawns_ignore_historical_reservations
test_project_mode_live_sync_registry
test_brief_and_spawn_live_sync_scope_contract
test_live_sync_backlog_failure_preserves_record
