#!/usr/bin/env bash
# tree-guard.sh: records the worktree's state and lists later every change outside the allowed paths, every move of HEAD and every leftover *.orca-bak.
# Usage (from anywhere in the worktree):  tree-guard.sh snapshot <file>
#                                         tree-guard.sh compare <file> [--allow <path>]...
#                                         tree-guard.sh -h | --help
# snapshot: writes the state to <file>, which must be outside the worktree: HEAD, and for every path git status reports its status,
#   its index content and its working-tree content. Refused when a *.orca-bak is left under the top (prints leftover <path> for each).
# compare: prints changed <path> for each path that differs, allowed <path> for the --allow ones, head <old> -> <new> when HEAD
#   moved, leftover <path> for each *.orca-bak, then one summary line.
# --allow: a path of the worktree (relative to its top or absolute inside it), repeatable; a folder allows every path under it.
# Exit codes: 0 nothing differs (or nothing outside the allowed paths), 1 refused or differences, 2 usage, 3 cannot compare.
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0
MARK=orca-tree-guard
die() { echo "tree-guard.sh: $*" >&2; exit 1; }
die2() { echo "tree-guard.sh: $*" >&2; exit 2; }
die3() { echo "tree-guard.sh: $*" >&2; exit 3; }
usage() { sed -n 3,5p "$0" >&2; exit 2; }
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
phys_path() {   # physical path of a path that may not exist yet: its nearest existing ancestor, resolved, plus the rest
  local p="$1" rest=""
  case "$p" in /*) ;; *) p="$PWD/$p";; esac
  while [ ! -d "$p" ]; do rest="/$(basename "$p")$rest"; p="$(dirname "$p")"; done
  case "$rest/" in */../*|*/./*) return 1;; esac
  printf '%s%s' "$(abs_dir "$p")" "$rest"
}
esc_path() {   # a path as one field of the state file: backslash, newline and tab escaped, so any name round-trips
  local p="$1"
  p="${p//\\/\\\\}"
  p="${p//$'\n'/\\n}"
  p="${p//$'\t'/\\t}"
  printf '%s' "$p"
}
unesc_path() {   # the raw path of a state field, in UNESC (a variable: a command would strip a trailing newline)
  local s="$1" out="" c i=0 n
  UNESC="$s"
  case "$s" in *'\'*) ;; *) return 0;; esac
  n=${#s}
  UNESC=""
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    if [ "$c" = '\' ] && [ $((i+1)) -lt "$n" ]; then
      i=$((i+1)); c="${s:$i:1}"
      case "$c" in n) out="$out"$'\n';; t) out="$out"$'\t';; *) out="$out$c";; esac
    else out="$out$c"; fi
    i=$((i+1))
  done
  UNESC="$out"
}
show_path() {   # a path as the reports print it: verbatim, or in double quotes with C escapes when it holds a newline, tab, quote or backslash
  local p="$1" q
  case "$p" in
    *$'\n'*|*$'\t'*|*'"'*|*'\'*)
      q="${p//\\/\\\\}"; q="${q//\"/\\\"}"; q="${q//$'\n'/\\n}"; q="${q//$'\t'/\\t}"
      printf '"%s"' "$q";;
    *) printf '%s' "$p";;
  esac
}
show_esc() { unesc_path "$1"; show_path "$UNESC"; }
entry() {   # entry <top> <status> <path>: one state line; a directory entry is the nested repo's HEAD plus its own state
  local top="$1" st="$2" p="$3" abs idx wt nh nest e
  abs="$top/$p"
  idx=""
  while IFS= read -r -d '' e; do
    e="${e%%$'\t'*}"
    idx="${idx}${idx:+,}$e"
  done < <(git -C "$top" ls-files -s -z -- ":(literal)$p" 2>/dev/null)
  [ -n "$idx" ] || idx="-"
  if [ -L "$abs" ]; then
    wt="$(readlink "$abs" 2>/dev/null | git hash-object --stdin)"
  elif [ -d "$abs" ]; then
    if [ -e "$abs/.git" ]; then
      nh="$(git -C "$abs" rev-parse --verify --quiet HEAD 2>/dev/null)" || nh="none"
      nest="$(entries "$abs")"
      if [ -n "$nest" ]; then wt="repo:$nh:$(printf '%s\n' "$nest" | git hash-object --stdin)"; else wt="repo:$nh:none"; fi
    else
      wt="dir"
    fi
  elif [ -e "$abs" ]; then
    wt="$(git hash-object -- "$abs" 2>/dev/null)"
  else
    wt="-"
  fi
  printf '%s\t%s\t%s\t%s\n' "$(esc_path "$p")" "$st" "$idx" "$wt"
}
entries() {   # entries <top>: the state of the repo at <top>, one sorted line per path its git status reports
  local top="$1"
  {
    while IFS= read -r -d '' rec; do
      [ -n "$rec" ] || continue
      entry "$top" "${rec:0:2}" "${rec:3}"
    done < <(git -C "$top" status --porcelain=v1 -z -uall --no-renames 2>/dev/null)
  } | LC_ALL=C sort
}
leftovers() {   # leftover *.orca-bak paths under <top> except inside a .git, as sorted state fields
  local top="$1" f
  {
    while IFS= read -r -d '' f; do esc_path "${f#"$top"/}"; printf '\n'; done \
      < <(find "$top" -mindepth 1 -name .git -prune -o -name '*.orca-bak' -print0 2>/dev/null)
  } | LC_ALL=C sort
}
is_allowed() {   # is_allowed <path>: whether a --allow value covers it (a folder covers every path under it)
  local q="${1%/}" a
  for a in ${AALLOW[@]+"${AALLOW[@]}"}; do
    [ -n "$a" ] || return 0
    if [ "$q" = "$a" ]; then return 0; fi
    case "$q" in "$a"/*) return 0;; esac
  done
  return 1
}
add_allow() {   # add_allow <value>: a path of the worktree; a bad value is a usage error
  local v="$1" rel="" a
  case "$v" in ''|/) die2 "--allow takes a non-empty path of the worktree";; esac
  case "/${v%/}/" in */../*|*/./*) die2 "--allow must not contain . or .. components: $v";; esac
  case "$v" in
    /*)
      a="$(phys_path "$v")" || die2 "--allow must be a path of the worktree: $v"
      case "$a" in
        "$TOP") rel="";;
        "$TOP"/*) rel="${a#"$TOP"/}";;
        *) die2 "--allow is outside the worktree: $v";;
      esac;;
    *) rel="${v%/}";;
  esac
  AALLOW+=("$rel")
}
head_sha() { HEAD_FULL="$(git rev-parse --verify --quiet HEAD 2>/dev/null)" || HEAD_FULL="none"; }
head_short() { HEAD_SHORT="$(git rev-parse --short HEAD 2>/dev/null)" || HEAD_SHORT="none"; }

case "${1:-}" in
  -h|--help) sed -n 2,11p "$0"; exit 0;;
  snapshot|compare) ;;
  *) usage;;
esac
CMD="$1"; shift

case "$CMD" in
  snapshot)
    [ $# = 1 ] && [ -n "$1" ] || usage
    FILE="$1"
    TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this from inside a git worktree"
    TOP="$(abs_dir "$TOP")" || die "cannot read the worktree's top"
    LEFTOVERS="$(leftovers "$TOP")"
    if [ -n "$LEFTOVERS" ]; then
      while IFS= read -r l; do printf 'leftover '; show_esc "$l"; printf '\n'; done <<< "$LEFTOVERS"
      die "refusing to take a snapshot: a *.orca-bak is left in the worktree"
    fi
    FD="$(phys_path "$FILE")" || die "the snapshot file must not contain . or .. after its existing part: $FILE"
    case "$FD/" in "$TOP"/*) die "the snapshot file must be outside the worktree: $FILE";; esac
    case "$FD" in */*) [ -d "${FD%/*}" ] || die "cannot write the snapshot: $FILE";; esac
    head_sha; head_short
    STATE="$(entries "$TOP")"
    { printf '%s 1\n' "$MARK"
      printf 'top %s\n' "$(esc_path "$TOP")"
      printf 'head %s %s\n' "$HEAD_FULL" "$HEAD_SHORT"
      [ -z "$STATE" ] || printf '%s\n' "$STATE"
    } > "$FILE" || die "cannot write the snapshot: $FILE"
    if [ -n "$STATE" ]; then N="$(printf '%s\n' "$STATE" | wc -l | tr -d ' ')"; else N=0; fi
    echo "tree-guard: snapshot of $N changed path(s) at $HEAD_SHORT" >&2
    ;;
  compare)
    [ $# -ge 1 ] && [ -n "$1" ] || usage
    FILE="$1"; shift
    AALLOW=()
    TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die3 "run this from inside a git worktree"
    TOP="$(abs_dir "$TOP")" || die3 "cannot read the worktree's top"
    while [ $# -gt 0 ]; do
      case "$1" in
        --allow) [ $# -ge 2 ] && [ -n "$2" ] || die2 "--allow needs a path"; add_allow "$2"; shift 2;;
        *) usage;;
      esac
    done
    [ -f "$FILE" ] && [ -r "$FILE" ] || die3 "no readable snapshot: $FILE"
    { IFS= read -r l1 && IFS= read -r l2 && IFS= read -r l3; } < "$FILE" || die3 "not a snapshot made by tree-guard.sh: $FILE"
    [ "$l1" = "$MARK 1" ] || die3 "not a snapshot made by tree-guard.sh: $FILE"
    case "$l2" in "top "*) ;; *) die3 "not a snapshot made by tree-guard.sh: $FILE";; esac
    unesc_path "${l2#top }"; SNAPTOP="$UNESC"
    case "$l3" in "head "*" "*) OLD="${l3#head }"; OLDSHORT="${OLD#* }"; OLD="${OLD%% *}";; *) die3 "not a snapshot made by tree-guard.sh: $FILE";; esac
    [ "$SNAPTOP" = "$TOP" ] || die3 "the snapshot was taken in another worktree: $SNAPTOP"
    head_sha; head_short
    STATE="$(entries "$TOP")"
    T="$(mktemp -d "${TMPDIR:-/tmp}/orca-tree-guard.XXXXXX")" || die3 "cannot create a temporary folder"
    trap 'rm -rf "$T"' EXIT
    sed -n '4,$p' "$FILE" > "$T/old"
    if [ -n "$STATE" ]; then printf '%s\n' "$STATE" > "$T/new"; else : > "$T/new"; fi
    MERGE="$(awk -F'\t' '
      FILENAME == ARGV[1] { o[$1]=$0; next }
      { n[$1]=$0 }
      END {
        for (k in o) if (!(k in n)) print k "\told";
        for (k in n) { if (!(k in o)) print k "\tnew"; else if (o[k] != n[k]) print k "\tdiff" }
      }' "$T/old" "$T/new" | LC_ALL=C sort)"
    DIFFS=0; ALLOWED=0
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      unesc_path "${l%$'\t'*}"
      if is_allowed "$UNESC"; then printf 'allowed '; show_path "$UNESC"; printf '\n'; ALLOWED=$((ALLOWED+1)); continue; fi
      DIFFS=$((DIFFS+1)); printf 'changed '; show_path "$UNESC"; printf '\n'
    done <<< "$MERGE"
    if [ "$HEAD_FULL" != "$OLD" ]; then printf 'head %s -> %s\n' "$OLDSHORT" "$HEAD_SHORT"; DIFFS=$((DIFFS+1)); fi
    LEFTOVERS="$(leftovers "$TOP")"
    if [ -n "$LEFTOVERS" ]; then
      while IFS= read -r l; do printf 'leftover '; show_esc "$l"; printf '\n'; DIFFS=$((DIFFS+1)); done <<< "$LEFTOVERS"
    fi
    if [ "$DIFFS" = 0 ]; then echo "tree-guard: same as the snapshot ($ALLOWED allowed)"; exit 0; fi
    echo "tree-guard: $DIFFS difference(s) outside the allowed paths"
    exit 1
    ;;
esac
