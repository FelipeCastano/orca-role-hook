#!/usr/bin/env bash
# Takes back the trust the kit gave to worktrees in ~/.claude.json (projects[<path>]; see trust_folder in lib.sh).
# Usage:  forget-trust.sh [--dry-run]           (from a worktree) forgets this worktree
#         forget-trust.sh --stale [--dry-run]   forgets every recorded folder that no longer exists
# Only the hasTrustDialogAccepted flag the kit set is removed; the project's entry goes only when nothing else is in it (a folder Claude Code
# already knew keeps its permissions and history). Only folders the kit recorded in $KIT/trusted.list are touched with --stale.
# --dry-run prints what would be removed and writes nothing.
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
forget() {  # forget <dir>: removes the flag the kit set; the entry goes only when nothing else is in it
  local d="$1" rc=0 has flag other
  has="$(jq -r --arg d "$d" 'if (.projects // {}) | has($d) then "yes" else "no" end' "$LINK" 2>/dev/null)" || has=no
  flag="$(jq -r --arg d "$d" '(.projects[$d] | objects | has("hasTrustDialogAccepted")) // false | if . then "yes" else "no" end' "$LINK" 2>/dev/null)" || flag=no
  other="$(jq -r --arg d "$d" '(.projects[$d] | objects | del(.hasTrustDialogAccepted) | length) // 0' "$LINK" 2>/dev/null)" || other=0
  if [ "$DRY" = 1 ]; then
    if [ "$has" = yes ]; then
      if [ "$other" = 0 ]; then echo "Would remove projects[$d] from $LINK."
      elif [ "$flag" = yes ]; then echo "Would remove the kit's trust flag from projects[$d] in $LINK (its other keys stay)."
      else echo "$d has no kit trust flag in $LINK."; fi
    fi
    listed "$d" && echo "Would remove $d from $LIST."
    [ "$has" = yes ] || listed "$d" || echo "Nothing to remove for $d."
    return 0
  fi
  safe_json_edit "$LINK" 'if ((.projects // {}) | has($dir)) then (if ((.projects[$dir] | objects | del(.hasTrustDialogAccepted)) // {}) == {} then del(.projects[$dir]) else .projects[$dir] |= (objects | del(.hasTrustDialogAccepted)) end) else . end' "$d" "$LINK.lock" || rc=$?
  case "$rc" in
    0) if [ "$other" = 0 ]; then echo "Removed $d from $LINK."
       else echo "Removed the kit's trust flag from projects[$d] in $LINK."; fi
       unlist "$d";;
    3) if [ "$has" = yes ]; then echo "$d has no kit trust flag in $LINK."; else echo "$d has no entry in $LINK."; fi; unlist "$d";;
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
