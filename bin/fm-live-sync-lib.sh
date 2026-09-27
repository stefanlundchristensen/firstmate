#!/usr/bin/env bash
# Shared live-sync project helpers.
#
# A live-sync project is a registered external directory that a worker edits in
# place without a branch, commit, pull request, or merge step.
# This library owns the path canonicalization, protection-policy evaluation, and
# durable scope-lock records that make that path safe enough for Firstmate to
# dispatch.
#
# Registry binding is owned by bin/fm-project-mode.sh:
#   - <name> [live-sync path=<absolute-root> policy=<policy-path>] - ...
# The policy path may be absolute or relative to the live root.
#
# Protection policy syntax is intentionally small:
#   allow <relative-path-or-shell-pattern>
#   protect <relative-path>
# Blank lines and lines whose first nonblank character is # are ignored.
# An allow line classifies a write scope as ordinary editable material.
# A protect line marks a core file or directory that must not overlap a write scope.
# Protect lines must be concrete paths; globbing there is refused so directory
# overlap can be decided deterministically.
# The policy file itself is always treated as protected, even if the file omits it.
# Absence of allow or protect lines refuses every live-sync dispatch.
#
# Scope locks live under state/live-sync-locks/ and are durable until teardown
# proves task-owned live-root writers are stopped before calling
# fm_live_sync_release_task; if that proof is unavailable, teardown retains the
# task record and lock.
# They are cooperative exclusion records, not an OS sandbox: a same-user worker
# can still write outside its declared scope unless its own tool enforces more.
# Firstmate mechanically validates the declared scopes and serializes overlapping
# declarations; the worker remains obligated to keep actual writes inside them.

set -u

FM_LIVE_SYNC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_LIVE_SYNC_LIB_DIR/fm-wake-lib.sh"

FM_LIVE_SYNC_ERROR=
FM_LIVE_SYNC_ROOT=
FM_LIVE_SYNC_POLICY=
FM_LIVE_SYNC_SCOPE_RELS=()
FM_LIVE_SYNC_SCOPE_ABS=()
FM_LIVE_SYNC_SCOPE_KINDS=()
FM_LIVE_SYNC_ALLOW_RELS=()
FM_LIVE_SYNC_ALLOW_KINDS=()
FM_LIVE_SYNC_PROTECT_RELS=()
FM_LIVE_SYNC_PROTECT_KINDS=()

fm_live_sync_error() {
  FM_LIVE_SYNC_ERROR=$1
  printf '%s\n' "$1" >&2
  return 1
}

fm_live_sync_trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

fm_live_sync_abs_existing() {  # <path>
  perl -MCwd=abs_path -e '
    my $p = abs_path($ARGV[0]);
    defined $p or exit 1;
    print $p;
  ' -- "$1"
}

fm_live_sync_sha() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_live_sync_path_is_ancestor_of() {  # <ancestor> <path>
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

fm_live_sync_join_rel_parts() {  # <part>...
  local out='' part
  for part in "$@"; do
    [ -n "$part" ] || continue
    if [ -z "$out" ]; then
      out=$part
    else
      out="$out/$part"
    fi
  done
  [ -n "$out" ] && printf '%s\n' "$out" || printf '.\n'
}

fm_live_sync_clean_relative() {  # <relative-path-or-pattern>
  local input=$1 part
  local -a parts
  case "$input" in
    ''|.) printf '.\n'; return 0 ;;
    /*) return 1 ;;
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  parts=()
  local old_ifs=$IFS
  local split=()
  IFS=/ read -r -a split <<< "$input"
  IFS=$old_ifs
  for part in "${split[@]}"; do
    case "$part" in
      ''|.) continue ;;
      ..) return 1 ;;
      *$'\n'*|*$'\r'*) return 1 ;;
      *) parts+=("$part") ;;
    esac
  done
  fm_live_sync_join_rel_parts "${parts[@]+"${parts[@]}"}"
}

fm_live_sync_has_glob() {  # <pattern>
  case "$1" in
    *'*'*|*'?'*|*'['*) return 0 ;;
  esac
  return 1
}

fm_live_sync_canonical_root() {  # <root>
  local root=$1 abs
  [ -n "$root" ] || return 1
  [ -d "$root" ] || return 1
  abs=$(fm_live_sync_abs_existing "$root") || return 1
  [ -n "$abs" ] && [ "$abs" != / ] || return 1
  printf '%s\n' "$abs"
}

fm_live_sync_canonical_policy() {  # <root-abs> <policy-token>
  local root=$1 token=$2 path abs
  [ -n "$token" ] || return 1
  case "$token" in
    /*) path=$token ;;
    *) path="$root/$token" ;;
  esac
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1
  abs=$(fm_live_sync_abs_existing "$path") || return 1
  [ -n "$abs" ] || return 1
  printf '%s\n' "$abs"
}

fm_live_sync_canonical_scope() {  # <root-abs> <scope>
  local root=$1 scope=$2 path parent base abs parent_abs kind rel clean
  [ -n "$scope" ] || return 1
  case "$scope" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$scope" in
    /*) path=$scope ;;
    *)
      clean=$(fm_live_sync_clean_relative "$scope") || return 1
      path=$root
      [ "$clean" = . ] || path="$root/$clean"
      ;;
  esac
  if [ -e "$path" ] || [ -L "$path" ]; then
    abs=$(fm_live_sync_abs_existing "$path") || return 1
    if [ -d "$path" ]; then kind='dir'; else kind='file'; fi
  else
    parent=${path%/*}
    base=${path##*/}
    [ "$parent" != "$path" ] || parent=.
    [ -n "$base" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
    parent_abs=$(fm_live_sync_abs_existing "$parent") || return 1
    abs="$parent_abs/$base"
    case "$scope" in */) kind='dir' ;; *) kind='file' ;; esac
  fi
  if [ "$abs" != "$root" ] && ! fm_live_sync_path_is_ancestor_of "$root" "$abs"; then
    return 1
  fi
  if [ "$abs" = "$root" ]; then
    rel=.
  else
    rel=${abs#"$root"/}
  fi
  FM_LIVE_SYNC_CANON_ABS=$abs
  FM_LIVE_SYNC_CANON_REL=$rel
  FM_LIVE_SYNC_CANON_KIND=$kind
}

fm_live_sync_policy_entry_kind() {  # <root-abs> <rel> <raw>
  local root=$1 rel=$2 raw=$3 path
  path=$root
  [ "$rel" = . ] || path="$root/$rel"
  if [ -d "$path" ] || [ "$rel" = . ]; then
    printf 'dir\n'
  else
    case "$raw" in */) printf 'dir\n' ;; *) printf 'file\n' ;; esac
  fi
}

fm_live_sync_policy_load() {  # <root-abs> <policy-abs>
  local root=$1 policy=$2 line trimmed verb rest rel kind policy_rel
  FM_LIVE_SYNC_ALLOW_RELS=()
  FM_LIVE_SYNC_ALLOW_KINDS=()
  FM_LIVE_SYNC_PROTECT_RELS=()
  FM_LIVE_SYNC_PROTECT_KINDS=()
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(fm_live_sync_trim "$line")
    case "$trimmed" in ''|'#'*) continue ;; esac
    case "$trimmed" in
      *[[:space:]]*)
        verb=${trimmed%%[[:space:]]*}
        rest=${trimmed#"$verb"}
        rest=$(fm_live_sync_trim "$rest")
        ;;
      *) fm_live_sync_error "live-sync policy $policy has a line without a path: $trimmed"; return 1 ;;
    esac
    [ -n "$rest" ] || { fm_live_sync_error "live-sync policy $policy has an empty $verb path"; return 1; }
    rel=$(fm_live_sync_clean_relative "$rest") || {
      fm_live_sync_error "live-sync policy $policy has an unsafe $verb path: $rest"
      return 1
    }
    case "$verb" in
      allow)
        kind=pattern
        if ! fm_live_sync_has_glob "$rel"; then
          kind=$(fm_live_sync_policy_entry_kind "$root" "$rel" "$rest")
        fi
        FM_LIVE_SYNC_ALLOW_RELS+=("$rel")
        FM_LIVE_SYNC_ALLOW_KINDS+=("$kind")
        ;;
      protect)
        if fm_live_sync_has_glob "$rel"; then
          fm_live_sync_error "live-sync policy $policy protect entries must be concrete paths, not patterns: $rest"
          return 1
        fi
        kind=$(fm_live_sync_policy_entry_kind "$root" "$rel" "$rest")
        FM_LIVE_SYNC_PROTECT_RELS+=("$rel")
        FM_LIVE_SYNC_PROTECT_KINDS+=("$kind")
        ;;
      *) fm_live_sync_error "live-sync policy $policy has unknown directive: $verb"; return 1 ;;
    esac
  done < "$policy"
  [ "${#FM_LIVE_SYNC_ALLOW_RELS[@]}" -gt 0 ] || {
    fm_live_sync_error "live-sync policy $policy has no allow lines; unclassified writes are refused"
    return 1
  }
  [ "${#FM_LIVE_SYNC_PROTECT_RELS[@]}" -gt 0 ] || {
    fm_live_sync_error "live-sync policy $policy has no protect lines; an explicit core-file contract is required"
    return 1
  }
  if [ "$policy" = "$root" ] || fm_live_sync_path_is_ancestor_of "$root" "$policy"; then
    if [ "$policy" = "$root" ]; then
      policy_rel=.
    else
      policy_rel=${policy#"$root"/}
    fi
    FM_LIVE_SYNC_PROTECT_RELS+=("$policy_rel")
    FM_LIVE_SYNC_PROTECT_KINDS+=(file)
  fi
}

fm_live_sync_rel_descendant() {  # <ancestor-rel> <rel>
  local ancestor=$1 rel=$2
  [ "$ancestor" != . ] || { [ "$rel" != . ]; return; }
  case "$rel" in "$ancestor"/*) return 0 ;; esac
  return 1
}

fm_live_sync_rel_overlaps() {  # <kind-a> <rel-a> <kind-b> <rel-b>
  local kind_a=$1 rel_a=$2 kind_b=$3 rel_b=$4
  [ "$rel_a" = "$rel_b" ] && return 0
  if [ "$kind_a" = dir ] && fm_live_sync_rel_descendant "$rel_a" "$rel_b"; then
    return 0
  fi
  if [ "$kind_b" = dir ] && fm_live_sync_rel_descendant "$rel_b" "$rel_a"; then
    return 0
  fi
  return 1
}

fm_live_sync_scope_allowed() {  # <kind> <rel>
  local kind=$1 rel=$2 i allow allow_kind
  for ((i=0; i < ${#FM_LIVE_SYNC_ALLOW_RELS[@]}; i++)); do
    allow=${FM_LIVE_SYNC_ALLOW_RELS[$i]}
    allow_kind=${FM_LIVE_SYNC_ALLOW_KINDS[$i]}
    case "$allow_kind" in
      pattern)
        # shellcheck disable=SC2254 # allow entries with glob metacharacters are intentional patterns.
        case "$rel" in $allow) return 0 ;; esac
        ;;
      dir)
        [ "$rel" = "$allow" ] && return 0
        fm_live_sync_rel_descendant "$allow" "$rel" && return 0
        ;;
      file)
        [ "$kind" = file ] && [ "$rel" = "$allow" ] && return 0
        ;;
    esac
  done
  return 1
}

fm_live_sync_scope_protected() {  # <kind> <rel>
  local kind=$1 rel=$2 i protected protected_kind
  for ((i=0; i < ${#FM_LIVE_SYNC_PROTECT_RELS[@]}; i++)); do
    protected=${FM_LIVE_SYNC_PROTECT_RELS[$i]}
    protected_kind=${FM_LIVE_SYNC_PROTECT_KINDS[$i]}
    if fm_live_sync_rel_overlaps "$kind" "$rel" "$protected_kind" "$protected"; then
      FM_LIVE_SYNC_PROTECTED_REL=$protected
      return 0
    fi
  done
  return 1
}

fm_live_sync_validate_scopes() {  # <root-abs> <policy-abs> <scope>...
  local root=$1 policy=$2 scope rel kind abs seen key existing
  shift 2
  [ "$#" -gt 0 ] || return 2
  fm_live_sync_policy_load "$root" "$policy" || return 1
  FM_LIVE_SYNC_SCOPE_RELS=()
  FM_LIVE_SYNC_SCOPE_ABS=()
  FM_LIVE_SYNC_SCOPE_KINDS=()
  seen=$'\n'
  for scope in "$@"; do
    fm_live_sync_canonical_scope "$root" "$scope" || {
      fm_live_sync_error "live-sync scope '$scope' does not resolve inside $root"
      return 1
    }
    rel=$FM_LIVE_SYNC_CANON_REL
    abs=$FM_LIVE_SYNC_CANON_ABS
    kind=$FM_LIVE_SYNC_CANON_KIND
    if ! fm_live_sync_scope_allowed "$kind" "$rel"; then
      fm_live_sync_error "live-sync scope '$scope' ($rel) is not allowed by $policy"
      return 1
    fi
    if fm_live_sync_scope_protected "$kind" "$rel"; then
      fm_live_sync_error "live-sync scope '$scope' ($rel) overlaps protected path $FM_LIVE_SYNC_PROTECTED_REL from $policy"
      return 1
    fi
    key="$kind $abs"
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    seen+="$key"$'\n'
    FM_LIVE_SYNC_SCOPE_RELS+=("$rel")
    FM_LIVE_SYNC_SCOPE_ABS+=("$abs")
    FM_LIVE_SYNC_SCOPE_KINDS+=("$kind")
  done
  [ "${#FM_LIVE_SYNC_SCOPE_RELS[@]}" -gt 0 ] || {
    fm_live_sync_error "live-sync scopes collapsed to an empty set"
    return 1
  }
  for ((i=0; i < ${#FM_LIVE_SYNC_SCOPE_RELS[@]}; i++)); do
    for ((j=i+1; j < ${#FM_LIVE_SYNC_SCOPE_RELS[@]}; j++)); do
      if fm_live_sync_abs_overlaps "${FM_LIVE_SYNC_SCOPE_KINDS[$i]}" "${FM_LIVE_SYNC_SCOPE_ABS[$i]}" \
          "${FM_LIVE_SYNC_SCOPE_KINDS[$j]}" "${FM_LIVE_SYNC_SCOPE_ABS[$j]}"; then
        existing=${FM_LIVE_SYNC_SCOPE_RELS[$i]}
        fm_live_sync_error "live-sync declared scopes overlap each other: $existing and ${FM_LIVE_SYNC_SCOPE_RELS[$j]}"
        return 1
      fi
    done
  done
}

fm_live_sync_abs_overlaps() {  # <kind-a> <abs-a> <kind-b> <abs-b>
  local kind_a=$1 abs_a=$2 kind_b=$3 abs_b=$4
  [ "$abs_a" = "$abs_b" ] && return 0
  if [ "$kind_a" = dir ] && fm_live_sync_path_is_ancestor_of "$abs_a" "$abs_b"; then
    return 0
  fi
  if [ "$kind_b" = dir ] && fm_live_sync_path_is_ancestor_of "$abs_b" "$abs_a"; then
    return 0
  fi
  return 1
}

fm_live_sync_lock_dir() {  # <state-dir>
  printf '%s/live-sync-locks\n' "$1"
}

fm_live_sync_index_lock() {  # <state-dir>
  printf '%s/.live-sync-locks.lock\n' "$1"
}

fm_live_sync_task_record() {  # <state-dir> <task-id>
  local state=$1 id=$2
  case "$id" in ''|*/*|*$'\n'*|*'..'*) return 1 ;; esac
  printf '%s/%s.lock\n' "$(fm_live_sync_lock_dir "$state")" "$id"
}

fm_live_sync_read_record_scopes() {  # <record>
  local record=$1 line kind abs rel
  FM_LIVE_SYNC_RECORD_KINDS=()
  FM_LIVE_SYNC_RECORD_ABS=()
  FM_LIVE_SYNC_RECORD_RELS=()
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      scope=$'dir\t'*|scope=$'file\t'*)
        line=${line#scope=}
        kind=${line%%$'\t'*}
        line=${line#*$'\t'}
        abs=${line%%$'\t'*}
        rel=${line#*$'\t'}
        case "$kind" in dir|file) ;; *) return 1 ;; esac
        case "$abs" in /*) ;; *) return 1 ;; esac
        [ -n "$rel" ] || return 1
        FM_LIVE_SYNC_RECORD_KINDS+=("$kind")
        FM_LIVE_SYNC_RECORD_ABS+=("$abs")
        FM_LIVE_SYNC_RECORD_RELS+=("$rel")
        ;;
    esac
  done < "$record"
  [ "${#FM_LIVE_SYNC_RECORD_KINDS[@]}" -gt 0 ]
}

fm_live_sync_acquire_task() {  # <state-dir> <task-id> <project-name> <root-abs> <policy-abs> <scope>...
  local state=$1 id=$2 project=$3 root=$4 policy=$5 lockdir index_lock record tmp other other_id i j
  shift 5
  fm_live_sync_validate_scopes "$root" "$policy" "$@" || return 1
  lockdir=$(fm_live_sync_lock_dir "$state")
  index_lock=$(fm_live_sync_index_lock "$state")
  record=$(fm_live_sync_task_record "$state" "$id") || {
    fm_live_sync_error "live-sync task id is unsafe for a lock record: $id"
    return 1
  }
  mkdir -p "$lockdir" || return 1
  fm_lock_acquire_wait "$index_lock" || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    if [ "${FM_LIVE_SYNC_ACQUIRE_REUSE_SAME_ID:-0}" != 1 ]; then
      fm_lock_release "$index_lock" || true
      fm_live_sync_error "live-sync task $id already has an active scope lock"
      return 1
    fi
  fi
  for other in "$lockdir"/*.lock; do
    [ -e "$other" ] || continue
    [ "$other" != "$record" ] || continue
    other_id=${other##*/}
    other_id=${other_id%.lock}
    if ! fm_live_sync_read_record_scopes "$other"; then
      fm_lock_release "$index_lock" || true
      fm_live_sync_error "live-sync lock record is unreadable or malformed: $other"
      return 1
    fi
    for ((i=0; i < ${#FM_LIVE_SYNC_SCOPE_ABS[@]}; i++)); do
      for ((j=0; j < ${#FM_LIVE_SYNC_RECORD_ABS[@]}; j++)); do
        if fm_live_sync_abs_overlaps "${FM_LIVE_SYNC_SCOPE_KINDS[$i]}" "${FM_LIVE_SYNC_SCOPE_ABS[$i]}" \
            "${FM_LIVE_SYNC_RECORD_KINDS[$j]}" "${FM_LIVE_SYNC_RECORD_ABS[$j]}"; then
          fm_lock_release "$index_lock" || true
          fm_live_sync_error "live-sync scope ${FM_LIVE_SYNC_SCOPE_RELS[$i]} overlaps active task $other_id scope ${FM_LIVE_SYNC_RECORD_RELS[$j]}"
          return 1
        fi
      done
    done
  done
  tmp="$record.tmp.${BASHPID:-$$}"
  {
    printf 'project=%s\n' "$project"
    printf 'root=%s\n' "$root"
    printf 'policy=%s\n' "$policy"
    for ((i=0; i < ${#FM_LIVE_SYNC_SCOPE_ABS[@]}; i++)); do
      printf 'scope=%s\t%s\t%s\n' "${FM_LIVE_SYNC_SCOPE_KINDS[$i]}" "${FM_LIVE_SYNC_SCOPE_ABS[$i]}" "${FM_LIVE_SYNC_SCOPE_RELS[$i]}"
    done
  } > "$tmp" || {
    rm -f -- "$tmp"
    fm_lock_release "$index_lock" || true
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp"
    fm_lock_release "$index_lock" || true
    return 1
  fi
  fm_lock_release "$index_lock" || return 1
}

fm_live_sync_release_task() {  # <state-dir> <task-id>
  local state=$1 id=$2 index_lock record
  record=$(fm_live_sync_task_record "$state" "$id") || return 1
  index_lock=$(fm_live_sync_index_lock "$state")
  mkdir -p "$(dirname "$record")" || return 1
  fm_lock_acquire_wait "$index_lock" || return 1
  rm -f -- "$record"
  fm_lock_release "$index_lock"
}

fm_live_sync_project_root() {  # <fm-root> <project-name>
  local root=$1 project=$2 value
  value=$("$root/bin/fm-project-mode.sh" --live-root "$project") || return 1
  case "$value" in /*) printf '%s\n' "$value" ;; *) return 1 ;; esac
}

fm_live_sync_project_policy_token() {  # <fm-root> <project-name>
  "$1/bin/fm-project-mode.sh" --live-policy "$2"
}
