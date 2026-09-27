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

test_scope_locks_exclude_only_overlaps() {
  local root policy state out
  root=$(make_vault locks)
  policy="$root/.firstmate-live-sync-policy"
  state="$TMP_ROOT/locks/state"
  mkdir -p "$state"
  root=$(fm_live_sync_canonical_root "$root") || fail "root did not canonicalize"
  policy=$(fm_live_sync_canonical_policy "$root" "$policy") || fail "policy did not canonicalize"

  fm_live_sync_acquire_task "$state" t1 vault "$root" "$policy" Notes/a.md || fail "initial lock should pass"
  if out=$(fm_live_sync_acquire_task "$state" t1 vault "$root" "$policy" Notes/b.md 2>&1); then
    fail "duplicate same-task fresh lock unexpectedly passed"
  fi
  assert_contains "$out" "already has an active scope lock" "duplicate same-task lock refusal did not name the active lock"
  FM_LIVE_SYNC_ACQUIRE_REUSE_SAME_ID=1 fm_live_sync_acquire_task "$state" t1 vault "$root" "$policy" Notes/a.md || fail "same-task relaunch lock reuse should pass"
  if out=$(fm_live_sync_acquire_task "$state" t2 vault "$root" "$policy" Notes/a.md 2>&1); then
    fail "overlapping lock unexpectedly passed"
  fi
  assert_contains "$out" "overlaps active task t1" "overlapping lock refusal did not name the owning task"

  fm_live_sync_acquire_task "$state" t3 vault "$root" "$policy" Notes/b.md || fail "disjoint file scope should lock concurrently"
  assert_present "$state/live-sync-locks/t1.lock" "first lock record missing"
  assert_present "$state/live-sync-locks/t3.lock" "disjoint lock record missing"

  fm_live_sync_release_task "$state" t1 || fail "lock release failed"
  fm_live_sync_acquire_task "$state" t2 vault "$root" "$policy" Notes/a.md || fail "released scope should be reusable"

  pass "fm-live-sync-lib: overlapping locks exclude each other while disjoint scopes run concurrently"
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

  out=$(FM_HOME="$home" "$PROJECT_MODE" yolo-vault 2>&1)
  rc=$?
  expect_code 3 "$rc" "live-sync +yolo registry refusal"
  assert_contains "$out" "live-sync has no merge step" "live-sync +yolo refusal did not name the merge-authority mismatch"

  out=$(FM_HOME="$home" "$PROJECT_MODE" forge-vault 2>&1)
  rc=$?
  expect_code 3 "$rc" "live-sync forge registry refusal"
  assert_contains "$out" "live-sync publishes nothing" "live-sync forge refusal did not name the publish mismatch"

  pass "fm-project-mode: live-sync root/policy queries and invalid token refusals"
}

fill_brief_subsections() {  # <file>
  local file=$1 content
  content=$(<"$file")
  content=${content//'{TASK}'/Edit the synthetic note.}
  content=${content//'{FIRSTMATE_SPEC}'/Stay inside Notes\/a.md.}
  printf '%s\n' "$content" > "$file"
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
  assert_absent "$lockfile" "failed fresh live-sync spawn left its scope lock behind"

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

  pass "fm-brief/fm-spawn: live-sync records scopes, refuses branch/yolo drift, and rolls back failed fresh locks"
}

test_policy_validation_and_canonicalization
test_scope_locks_exclude_only_overlaps
test_project_mode_live_sync_registry
test_brief_and_spawn_live_sync_scope_contract
