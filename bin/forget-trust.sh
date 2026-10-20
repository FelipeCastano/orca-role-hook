#!/usr/bin/env bash
# Takes back the trust the kit gave to worktrees in ~/.claude.json (projects[<path>]; see trust_folder in lib.sh).
# Usage:  forget-trust.sh [--dry-run]           (from a worktree) forgets this worktree
#         forget-trust.sh --stale [--dry-run]   forgets every recorded folder that no longer exists
# Only folders the kit recorded in $KIT/trusted.list are touched with --stale. --dry-run prints what would be removed and writes nothing.
# The files of custom agents (role field "trust") are not cleaned: their filter is opaque to the kit.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
STALE=0; DRY=0
for a in "$@"; do case "$a" in
  --stale) STALE=1;; --dry-run) DRY=1;;
  *) echo "Usage: forget-trust.sh [--stale] [--dry-run]" >&2; exit 2;;
esac; done
LINK="$HOME/.claude.json"; LIST="$(trusted_list)"

listed() { grep -qxF -- "$1" "$LIST" 2>/dev/null; }
unlist() {  # unlist <dir>: drops that line from trusted.list, atomically
  [ -f "$LIST" ] || return 0
  local tmp="$LIST.tmp.$$"
  awk -v d="$1" '$0 != d' "$LIST" > "$tmp" && mv "$tmp" "$LIST" || { rm -f "$tmp"; echo "Warning: could not update $LIST." >&2; }
}
forget() {  # forget <dir>
  local d="$1" rc=0 has
  if [ "$DRY" = 1 ]; then
    has="$(jq -r --arg d "$d" 'if (.projects // {}) | has($d) then "yes" else "no" end' "$LINK" 2>/dev/null)" || has=no
    [ "$has" = yes ] && echo "Would remove projects[$d] from $LINK."
    listed "$d" && echo "Would remove $d from $LIST."
    [ "$has" = yes ] || listed "$d" || echo "Nothing to remove for $d."
    return 0
  fi
  safe_json_edit "$LINK" 'del(.projects[$dir])' "$d" "$LINK.lock" || rc=$?
  case "$rc" in
    0) echo "Removed $d from $LINK."; unlist "$d";;
    3) echo "$d has no entry in $LINK."; unlist "$d";;
    *) echo "Warning: could not remove $d from $LINK ($([ "$rc" = 2 ] && echo 'the file kept changing' || echo 'it could not be read or written')); $LINK was left untouched." >&2;;
  esac
}

if [ "$STALE" = 1 ]; then
  [ -f "$LIST" ] || { echo "Nothing recorded in $LIST."; exit 0; }
  n=0
  while IFS= read -r p; do
    [ -n "$p" ] && [ ! -d "$p" ] || continue
    forget "$p"; n=$((n + 1))
  done < <(cat "$LIST")
  [ "$n" -gt 0 ] || echo "No recorded folder is missing."
else
  forget "$(pwd -P)"
fi
exit 0
