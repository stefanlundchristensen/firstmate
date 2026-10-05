#!/usr/bin/env bash
# Validate live-sync project scopes.
# Usage:
#   fm-live-sync.sh info <project>
#   fm-live-sync.sh check <project> --scope <relative-path> [--scope <relative-path>...]
#
# stdout is concise agent-readable text; errors are printed to stdout and return
# non-zero so a caller can relay the refusal directly.
# `info` prints the registered root and policy after canonicalization.
# `check` validates path canonicalization, explicit policy classification, and
# protected-path exclusion. It does not reserve files or coordinate workers.
#
# This tool is not a sandbox. Multiple workers may target overlapping live files;
# firstmate must assign non-conflicting work, and each worker must keep actual
# writes inside its declared scopes.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-live-sync-lib.sh
. "$SCRIPT_DIR/fm-live-sync-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command=${1:-}
[ -n "$command" ] || { usage; exit 2; }
shift

scopes=()
parse_scopes() {
  local want_scope='' arg
  scopes=()
  for arg in "$@"; do
    if [ -n "$want_scope" ]; then
      case "$arg" in --*) printf 'error: --scope requires a value\n'; return 2 ;; esac
      scopes+=("$arg")
      want_scope=
      continue
    fi
    case "$arg" in
      --scope) want_scope=1 ;;
      --scope=*) scopes+=("${arg#--scope=}") ;;
      *) printf 'error: unknown argument for %s: %s\n' "$command" "$arg"; return 2 ;;
    esac
  done
  [ -z "$want_scope" ] || { printf 'error: --scope requires a value\n'; return 2; }
  [ "${#scopes[@]}" -gt 0 ] || { printf 'error: at least one --scope is required\n'; return 2; }
}

load_project() {  # <project>
  local project=$1 root_token policy_token root policy
  root_token=$(fm_live_sync_project_root "$FM_ROOT" "$project" 2>&1) || {
    printf 'error: %s\n' "$root_token"
    return 1
  }
  policy_token=$(fm_live_sync_project_policy_token "$FM_ROOT" "$project" 2>&1) || {
    printf 'error: %s\n' "$policy_token"
    return 1
  }
  root=$(fm_live_sync_canonical_root "$root_token") || {
    printf 'error: live-sync root for %s is not a readable non-root directory: %s\n' "$project" "$root_token"
    return 1
  }
  policy=$(fm_live_sync_canonical_policy "$root" "$policy_token") || {
    printf 'error: live-sync policy for %s is not a readable regular file: %s\n' "$project" "$policy_token"
    return 1
  }
  FM_LIVE_SYNC_ROOT=$root
  FM_LIVE_SYNC_POLICY=$policy
}

print_scopes() {
  local i
  printf 'scopes[%s]{kind,rel,abs}:\n' "${#FM_LIVE_SYNC_SCOPE_RELS[@]}"
  for ((i=0; i < ${#FM_LIVE_SYNC_SCOPE_RELS[@]}; i++)); do
    printf '  %s,%s,%s\n' "${FM_LIVE_SYNC_SCOPE_KINDS[$i]}" "${FM_LIVE_SYNC_SCOPE_RELS[$i]}" "${FM_LIVE_SYNC_SCOPE_ABS[$i]}"
  done
}

case "$command" in
  info)
    [ "$#" -eq 1 ] || { printf 'error: info requires exactly one project\n'; exit 2; }
    load_project "$1" || exit 1
    printf 'project: %s\n' "$1"
    printf 'root: %s\n' "$FM_LIVE_SYNC_ROOT"
    printf 'policy: %s\n' "$FM_LIVE_SYNC_POLICY"
    ;;
  check)
    [ "$#" -ge 1 ] || { printf 'error: check requires a project\n'; exit 2; }
    project=$1
    shift
    parse_scopes "$@" || exit $?
    load_project "$project" || exit 1
    if ! fm_live_sync_validate_scopes "$FM_LIVE_SYNC_ROOT" "$FM_LIVE_SYNC_POLICY" "${scopes[@]}" 2>/dev/null; then
      printf 'error: %s\n' "$FM_LIVE_SYNC_ERROR"
      exit 1
    fi
    printf 'ok: live-sync scopes are allowed for %s\n' "$project"
    print_scopes
    ;;
  *)
    printf 'error: unknown command %s\n' "$command"
    usage
    exit 2
    ;;
esac
