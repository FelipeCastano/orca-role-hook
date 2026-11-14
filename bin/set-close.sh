#!/usr/bin/env bash
# Closes the tabs of a set at its close: one canary check, then per tab its pair tree's checkpoints, its pair tree and its tab.
# Usage (from the worktree where the roles were opened):  set-close.sh --run <run_id> <role|instance|title|handle> [...]   (at least one tab)
# Only for the set close, after the set's commits: it always reads team-status with --after-commits (so it also closes the Plan-Reviewer and
# the Code-Reviewer) and deletes the tabs' pair-tree checkpoints; before the commits, close a tab with close-role.sh.
# A tab it closes is one that team-status.sh --json --run <run_id> --after-commits marks closable (a tab, state done, interrupted or failed,
# no open dispatch of that Run to its handle, opened per batch, per task or as an instance). It never closes the local coordinator; every
# other named tab it refuses is left as it is, and so are the tabs it was not given.
# Per accepted tab, in argument order: its pair tree's checkpoint refs (when its registry line is integrated or removed and no other open tab
# outside this call runs in the same tree), pair-tree.sh remove <batch> (when that line is integrated), close-role.sh <id>. A pair tree still
# used by another open tab is kept, with its refs, and one line says so.
# It cannot tell whether the set is committed: run it only after the commits.
# Exit 0: every named tab closed and canary exit 0; 1: some tab refused or failed, or canary exit 1 (the other tabs are still processed);
# 2: nothing changed (usage, no team, from a pair tree, an argument naming no open tab, team-status or canary exit 2).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
usage() { sed -n 3,14p "$0" >&2; exit 2; }
die2() { echo "set-close: $*" >&2; exit 2; }
RUN=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --run) [ $# -ge 2 ] || usage; RUN="$2"; shift;;
    -*) usage;;
    *) ARGS+=("$1");;
  esac
  shift
done
[ -n "$RUN" ] && [ "${#ARGS[@]}" -gt 0 ] || usage
git rev-parse --show-toplevel >/dev/null 2>&1 || die2 "run this from inside the worktree where the roles were opened"
GD="$(git rev-parse --absolute-git-dir 2>/dev/null)" || die2 "run this from inside the worktree where the roles were opened"
[ ! -e "$GD/orca-roles.pair" ] || die2 "this is a pair tree: run it from the worktree where the roles were opened"
STATE="${ORCA_ROLES_STATE:-$GD/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GD/orca-roles.config.json}"
[ -s "$STATE" ] || die2 "no orca-roles team in this folder: run this from the worktree where the roles were opened"
[ -f "$CFG" ] || CFG=/dev/null
TD="$(dirname "$STATE")"; TREES="$TD/orca-roles.trees"; REG="$GD/orca-roles.pairs"

# shellcheck source=/dev/null
. "$STATE"
IDS="$(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-')"
lower() { tr 'A-Z' 'a-z'; }
title() { local t; t="$(title_of "$CFG" "$1" 2>/dev/null)"; printf '%s' "${t:-$1}"; }
resolve() {  # <role|title|handle> → role id
  local x="$1" id v
  for id in $IDS; do
    v="$(var_of "$id")"
    if [ "$x" = "$id" ] || [ "$(printf '%s' "$x" | lower)" = "$(title "$id" | lower)" ] || [ "$x" = "${!v}" ]; then echo "$id"; return; fi
  done
}
phys() { (cd "$1" 2>/dev/null && pwd -P) 2>/dev/null || printf '%s' "$1"; }
regline() {  # <physical pair tree path> → its registry line (the open or integrated one, else the last one)
  [ -f "$REG" ] || return 0
  awk -F'\t' -v p="$1" '
    { if ($3 != p) next; if ($6 == "open" || $6 == "integrated") { print; found = 1; exit } last = $0 }
    END { if (!found && last != "") print last }' "$REG"
}
is_accepted() { local a; for a in "${ACC[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
other_tab() {  # <physical pair tree path> → Title of the first open tab outside this call that runs in it, or nothing
  local v _ hp id
  while IFS='=' read -r v _; do
    [ -n "$v" ] || continue
    id="$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')"
    is_accepted "$id" && continue
    hp="$(grep "^$v=" "$TREES" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "$hp" ] || continue
    [ "$(phys "$hp")" = "$1" ] || continue
    title "$id"; return
  done < "$STATE"
}
del_refs() {  # <physical pair tree path> <pair git dir>: deletes the tree's checkpoint refs; fails when one is left
  local h wt r
  h="$(printf '%s' "$2" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | cut -d' ' -f1 | cut -c1-10)"
  wt="$(basename "$1" | tr -c 'A-Za-z0-9\n-' '-' | sed 's/^-*//')"; wt="${wt:-wt}-$h"
  while IFS= read -r r; do [ -n "$r" ] && git update-ref -d "$r" >/dev/null; done < <(git for-each-ref --format='%(refname)' "refs/orca-roles/checkpoints/$wt/")
  [ -z "$(git for-each-ref --format='%(refname)' "refs/orca-roles/checkpoints/$wt/")" ]
}

SEL=(); SELS=" "
for x in "${ARGS[@]}"; do
  id="$(resolve "$x")"
  [ -n "$id" ] || die2 "no open tab '$x' in this workspace. Open tabs: $(echo $IDS)"
  case "$SELS" in *" $id "*) ;; *) SEL+=("$id"); SELS="$SELS$id ";; esac
done

TSOUT="$(mktemp)"; TSERR="$(mktemp)"; trap 'rm -f "$TSOUT" "$TSERR"' EXIT
"$KIT/bin/team-status.sh" --json --run "$RUN" --after-commits >"$TSOUT" 2>"$TSERR"; TSRC=$?
cat "$TSERR" >&2
[ "$TSRC" = 0 ] || exit 2

ACC=(); REFUSED=0; RC=0
for id in "${SEL[@]}"; do
  t="$(title "$id")"
  row="$(jq -c --arg r "$id" '[.[] | select(.role == $r)] | first // empty' "$TSOUT")"
  st=""; [ -z "$row" ] || st="$(printf '%s' "$row" | jq -r '.state')"
  if [ -z "$row" ] || [ "$(printf '%s' "$row" | jq -r '.closable')" != true ]; then
    echo "set-close: $t: refused: not closable (state ${st:--})"; REFUSED=$((REFUSED + 1)); RC=1; continue
  fi
  p="$(grep "^$(var_of "$id")=" "$TREES" 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ -n "$p" ]; then
    line="$(regline "$(phys "$p")")"
    if [ "$(printf '%s' "$line" | cut -f6)" = open ]; then
      echo "set-close: $t: refused: its pair tree (batch $(printf '%s' "$line" | cut -f1)) was not integrated"; REFUSED=$((REFUSED + 1)); RC=1; continue
    fi
  fi
  ACC+=("$id")
done

if [ "${#ACC[@]}" -eq 0 ]; then echo "set-close: 0 closed, $REFUSED refused"; exit 1; fi
"$KIT/bin/canary.sh" --run "$RUN"; CRC=$?
[ "$CRC" != 2 ] || exit 2
[ "$CRC" = 0 ] || RC=1

CLOSED=0
for id in "${ACC[@]}"; do
  t="$(title "$id")"
  p="$(grep "^$(var_of "$id")=" "$TREES" 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ -n "$p" ]; then
    pp="$(phys "$p")"; line="$(regline "$pp")"; st="$(printf '%s' "$line" | cut -f6)"
    if [ -n "$line" ] && [ "$st" != open ]; then
      other="$(other_tab "$pp")"
      if [ -n "$other" ]; then
        echo "set-close: $t: pair tree kept: $other still runs in it"
      else
        if ! del_refs "$pp" "$(printf '%s' "$line" | cut -f5)"; then
          echo "set-close: $t: checkpoints failed"; REFUSED=$((REFUSED + 1)); RC=1; continue
        fi
        if [ "$st" = integrated ] && ! "$KIT/bin/pair-tree.sh" remove "$(printf '%s' "$line" | cut -f1)"; then
          echo "set-close: $t: pair tree failed"; REFUSED=$((REFUSED + 1)); RC=1; continue
        fi
      fi
    fi
  fi
  if "$KIT/bin/close-role.sh" "$id"; then CLOSED=$((CLOSED + 1))
  else echo "set-close: $t: close failed"; REFUSED=$((REFUSED + 1)); RC=1; fi
done
echo "set-close: $CLOSED closed, $REFUSED refused"
exit "$RC"
