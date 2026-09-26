#!/usr/bin/env bash
# Live Treehouse regressions for fm-teardown slot cleanup decisions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_TEARDOWN_LIVE_TREEHOUSE treehouse git perl

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-live-treehouse)
LIVE_CASES=()
LIVE_WORKERS=()

live_path_in_case() {  # <case> <path> <description>
  local dir=$1 path=$2 description=$3 abs
  [ -n "$path" ] || fail "$description: empty path"
  abs=$(cd -P -- "$(dirname "$path")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")") \
    || fail "$description: cannot canonicalize $path"
  case "$abs" in
    "$dir"/*) ;;
    *) fail "$description: $abs escapes fixture $dir" ;;
  esac
}

assert_live_case_isolated() {  # <case>
  local dir=$1 repo_root
  live_path_in_case "$TMP_ROOT" "$dir" "fixture root"
  live_path_in_case "$dir" "$dir/home" "FM_HOME"
  live_path_in_case "$dir" "$dir/treehouse-root" "Treehouse root"
  live_path_in_case "$dir" "$dir/repo" "synthetic repo"
  repo_root=$(git -C "$dir/repo" rev-parse --show-toplevel 2>/dev/null) \
    || fail "fixture repo is not a git repository"
  [ "$repo_root" = "$dir/repo" ] || fail "fixture repo root drifted to $repo_root"
}

live_cleanup() {
  local worker dir slot project root marker
  for worker in "${LIVE_WORKERS[@]:-}"; do
    [ -n "$worker" ] || continue
    kill "$worker" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
  done
  for dir in "${LIVE_CASES[@]:-}"; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    assert_live_case_isolated "$dir"
    slot=$(cat "$dir/slot-path" 2>/dev/null || true)
    project="$dir/repo"
    root="$dir/treehouse-root"
    if [ -n "$slot" ] && [ -d "$slot" ]; then
      marker="$(dirname "$slot")/.fm-slot-owner"
      rm -f "$marker" 2>/dev/null || true
      ( cd "$project" && TREEHOUSE_ROOT="$root" treehouse return --force "$slot" >/dev/null 2>&1 ) || true
    fi
  done
  fm_test_cleanup
}
trap live_cleanup EXIT
trap 'live_cleanup; exit 130' INT
trap 'live_cleanup; exit 143' TERM
trap 'live_cleanup; exit 129' HUP
trap 'live_cleanup; exit 131' QUIT

make_live_case() {  # <output-var> <name>
  local -n __out=$1
  local name=$2 case_dir slot
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin" "$case_dir/repo" "$case_dir/treehouse-root"
  git init -q "$case_dir/repo"
  git -C "$case_dir/repo" config user.name test
  git -C "$case_dir/repo" config user.email test@example.invalid
  git -C "$case_dir/repo" commit --allow-empty -qm fixture-root
  slot=$(cd "$case_dir/repo" && TREEHOUSE_ROOT="$case_dir/treehouse-root" \
    treehouse get --lease --no-fetch 2>"$case_dir/treehouse-get.err") \
    || fail "treehouse get failed: $(cat "$case_dir/treehouse-get.err")"
  [ -d "$slot" ] || fail "treehouse get returned missing slot $slot"
  printf '%s\n' "$slot" > "$case_dir/slot-path"
  ln -s "$slot" "$case_dir/worktree-alias"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$case_dir/runtime.log"
  LIVE_CASES+=("$case_dir")
  assert_live_case_isolated "$case_dir"
  __out=$case_dir
}

claim_slot() {  # <case> <task-id> [home]
  local dir=$1 id=$2 home=${3:-$1/home} slot marker
  slot=$(cat "$dir/slot-path")
  marker="$(dirname "$slot")/.fm-slot-owner"
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$marker"
}

run_teardown() {  # <case> <id> [args...]
  local dir=$1 id=$2
  shift 2
  assert_live_case_isolated "$dir"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" TREEHOUSE_ROOT="$dir/treehouse-root" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

treehouse_status_for_slot() {  # <case>
  local dir=$1 slot
  slot=$(cat "$dir/slot-path")
  ( cd "$dir/repo" && TREEHOUSE_ROOT="$dir/treehouse-root" treehouse status --json 2>/dev/null ) |
    perl -MJSON::PP -e '
      local $/;
      my $data = JSON::PP->new->decode(<STDIN>);
      my $want = shift;
      for my $entry (@$data) {
        next unless $entry->{path} eq $want;
        print (($entry->{status} // ""), "\n");
        exit 0;
      }
      exit 1;
    ' "$slot"
}

assert_treehouse_available() {  # <case> <description>
  local dir=$1 description=$2 status
  status=$(treehouse_status_for_slot "$dir") || fail "$description: slot missing from treehouse status"
  [ "$status" = available ] || fail "$description: slot status is $status, not available"
}

assert_treehouse_leased() {  # <case> <description>
  local dir=$1 description=$2 status
  status=$(treehouse_status_for_slot "$dir") || fail "$description: slot missing from treehouse status"
  [ "$status" = leased ] || fail "$description: slot status is $status, not leased"
}

test_live_sole_owner_returns_recorded_treehouse_path() {
  local dir id=live-owned slot
  make_live_case dir live-owned
  slot=$(cat "$dir/slot-path")
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree-alias" "project=$dir/repo" "kind=scout"
  claim_slot "$dir" "$id"

  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr" \
    || fail "live owned slot teardown failed: $(cat "$dir/stderr")"

  assert_absent "$dir/home/state/$id.meta" "live owned teardown left task metadata"
  assert_absent "$(dirname "$slot")/.fm-slot-owner" "live owned teardown left its slot claim"
  assert_treehouse_available "$dir" "live owned teardown did not return the Treehouse slot"
  assert_contains "$(cat "$dir/stderr")" "using Treehouse state path $slot" \
    "live owned teardown should return Treehouse's recorded path, not the metadata alias"
  pass "live Treehouse: sole owner returns the recorded slot path"
}

test_live_reassigned_slot_retires_only_stale_record() {
  local dir id=live-stale other=live-owner slot worker rc
  make_live_case dir live-reassigned
  slot=$(cat "$dir/slot-path")
  : > "$slot/sentinel"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$slot" "project=$dir/repo" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$slot" "project=$dir/repo" "kind=scout"
  claim_slot "$dir" "$other" "$dir/other-home"
  ( cd "$slot" && exec sleep 30 ) &
  worker=$!
  LIVE_WORKERS+=("$worker")

  set +e
  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "live reassigned stale cleanup failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "live reassigned cleanup killed the slot owner's worker"
  assert_absent "$dir/home/state/$id.meta" "live reassigned cleanup left stale metadata"
  assert_present "$dir/home/state/$other.meta" "live reassigned cleanup removed current owner metadata"
  assert_present "$(dirname "$slot")/.fm-slot-owner" "live reassigned cleanup removed current owner claim"
  assert_contains "$(cat "$(dirname "$slot")/.fm-slot-owner")" "task=$other" \
    "live reassigned cleanup rewrote current owner claim"
  assert_present "$slot/.git" "live reassigned cleanup removed the current owner's checkout"
  assert_present "$slot/sentinel" "live reassigned cleanup reset the current owner's checkout"
  assert_treehouse_leased "$dir" "live reassigned cleanup returned another task's slot"
  assert_contains "$(cat "$dir/stderr")" "reassigned to task $other" \
    "live reassigned cleanup should warn about the current owner"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  pass "live Treehouse: reassigned slot preserves the current owner"
}

test_live_uncertain_claim_refuses_before_mutation() {
  local dir id=live-uncertain slot marker rc
  make_live_case dir live-uncertain
  slot=$(cat "$dir/slot-path")
  marker="$(dirname "$slot")/.fm-slot-owner"
  : > "$slot/sentinel"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$slot" "project=$dir/repo" "kind=scout"
  printf 'not-a-readable-claim\n' > "$marker"

  set +e
  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "live uncertain claim unexpectedly cleaned up"
  assert_present "$dir/home/state/$id.meta" "live uncertain claim removed task metadata"
  assert_present "$slot/sentinel" "live uncertain claim changed the checkout"
  assert_present "$marker" "live uncertain claim removed the claim"
  [ ! -s "$dir/runtime.log" ] \
    || fail "live uncertain claim reached the runtime: $(cat "$dir/runtime.log")"
  assert_treehouse_leased "$dir" "live uncertain claim returned the slot"
  assert_contains "$(cat "$dir/stderr")" "$marker" \
    "live uncertain claim refusal should name the claim file"
  pass "live Treehouse: uncertain slot-owner claims refuse before mutation"
}

test_live_sole_owner_returns_recorded_treehouse_path
test_live_reassigned_slot_retires_only_stale_record
test_live_uncertain_claim_refuses_before_mutation
