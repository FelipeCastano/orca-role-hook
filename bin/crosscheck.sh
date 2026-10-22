#!/usr/bin/env bash
# Throwaway copies of the worktree at a given ref, for running tests against code other than the tree Dev left (the step's base,
# for example) without touching the worktree. A copy lives in the worker's scratchDir and carries its own throwaway git repo.
# Usage (from the worktree):  crosscheck.sh tree <dir> --ref <ref> [--overlay <file>...]
#                             crosscheck.sh run <dir> --label <label> [--timeout <seconds>] -- <command> [<arg>...]
#                             crosscheck.sh export <dir> [--only <path>]... [--except <path>]...   |   crosscheck.sh apply <dir> <patch>
# tree: writes the files of <ref> (a commit, e.g. a checkpoint ref) into <dir>, outside the worktree: new, empty, or an earlier copy
#   (replaced). Links the worktree's ignored entries (dependencies such as node_modules or .venv; caches excluded) instead of copying
#   them, commits the copy in a repo of its own, then copies each --overlay file (a path of the worktree, e.g. the tests you wrote) on
#   top, uncommitted.
# run: runs the command inside a copy made by tree, cut after --timeout seconds (default 600); its output goes to <dir>.<label>.log
#   and one JSON line is printed: {label, dir, exit, seconds, timedOut, log}. A timed-out run is an error, not a failing test.
# export: prints, as a binary-safe patch, what changed in a copy since tree made it (new files included, links left out), limited to
#   the --only paths and without the --except ones (literal paths of the project, files or folders). Nothing to export: empty output.
# apply: applies a patch (e.g. one export printed) to a copy, all or nothing. An empty patch changes nothing.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
MARK=orca-crosscheck
die() { echo "crosscheck.sh: $*" >&2; exit 1; }
usage() { sed -n 4,6p "$0" >&2; exit 2; }
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }   # physical path of an existing directory
phys_path() {   # physical path of a directory that may not exist yet: its nearest existing ancestor, resolved, plus the rest
  local p="$1" rest=""
  case "$p" in /*) ;; *) p="$PWD/$p";; esac
  while [ ! -d "$p" ]; do rest="/$(basename "$p")$rest"; p="$(dirname "$p")"; done
  case "$rest/" in */../*|*/./*) return 1;; esac
  printf '%s%s' "$(abs_dir "$p")" "$rest"
}
is_copy() { [ -f "$1/.git/$MARK" ]; }

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this from inside the worktree"
TOP="$(abs_dir "$TOP")"
CMD="${1:-}"; [ -n "$CMD" ] || usage; shift

case "$CMD" in
  tree)
    DIR="${1:-}"; [ -n "$DIR" ] || usage; shift
    REF=""; OVERLAYS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --ref) [ -n "${2:-}" ] || die "--ref needs a value"; REF="$2"; shift 2;;
        --overlay) [ -n "${2:-}" ] || die "--overlay needs a file"; OVERLAYS+=("$2"); shift 2;;
        *) usage;;
      esac
    done
    [ -n "$REF" ] || die "--ref <ref> is required"
    SHA="$(git rev-parse --verify --quiet "$REF^{commit}")" || die "not a commit: $REF"
    for f in ${OVERLAYS[@]+"${OVERLAYS[@]}"}; do
      case "$f" in /*) rel="${f#"$TOP"/}"; [ "$rel" != "$f" ] || die "overlay outside the worktree: $f";; *) rel="$f";; esac
      case "/$rel/" in */../*|*/./*) die "overlay path must not contain . or ..: $f";; esac
      [ -f "$TOP/$rel" ] && [ ! -L "$TOP/$rel" ] || die "overlay is not a regular file of the worktree: $f"
    done
    REPLACE=0
    if [ -e "$DIR" ] || [ -L "$DIR" ]; then
      if [ -d "$DIR" ] && [ ! -L "$DIR" ] && is_copy "$DIR"; then REPLACE=1
      else [ -d "$DIR" ] && [ -z "$(ls -A "$DIR" 2>/dev/null)" ] || die "$DIR exists and is neither empty nor a copy made by crosscheck.sh tree"; fi
    fi
    D="$(phys_path "$DIR")" || die "$DIR must not contain . or .. after its existing part"
    case "$D/" in "$TOP"/*) die "$DIR is inside the worktree: use your scratchDir";; esac
    case "$TOP/" in "$D"/*) die "$DIR contains the worktree";; esac
    # an earlier copy is replaced (scratch folders are reused, never emptied by hand); rm -rf removes its links, not what they point to
    if [ "$REPLACE" = 1 ]; then rm -rf "$D" || die "cannot remove the earlier copy in $DIR"; fi
    mkdir -p "$D" || die "cannot create $DIR"
    T="$(mktemp -d "${TMPDIR:-/tmp}/orca-crosscheck.XXXXXX")" || die "cannot create a temporary folder"
    trap 'rm -rf "$T"' EXIT
    # read-tree + checkout-index rather than git archive, which would drop export-ignore paths (often the tests)
    GIT_INDEX_FILE="$T/index" git read-tree "$SHA" && GIT_INDEX_FILE="$T/index" git --work-tree="$D" checkout-index -a -f \
      || die "cannot extract $REF into $DIR"
    # ignored entries of the worktree whose parent exists in the copy: linked, never copied; caches stay out (a run would write into the worktree's)
    LINKS=()
    while IFS= read -r p; do
      p="${p%/}"; [ -n "$p" ] || continue
      case "/$p" in */__pycache__|*/.pytest_cache|*/.mypy_cache|*/.ruff_cache|*/.DS_Store) continue;; esac
      parent="$(dirname "$p")"
      [ -d "$D/$parent" ] && [ ! -e "$D/$p" ] && [ ! -L "$D/$p" ] || continue
      ln -s "$TOP/$p" "$D/$p" && LINKS+=("$p")
    done < <(git -C "$TOP" ls-files -o -i --exclude-standard --directory 2>/dev/null)
    g() { git -C "$D" -c user.name=crosscheck -c user.email=crosscheck@localhost -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
    g init -q || die "cannot create the copy's repo in $DIR"
    for p in ${LINKS[@]+"${LINKS[@]}"}; do printf '/%s\n' "$p"; done >> "$D/.git/info/exclude"
    g add -A && g commit -q --allow-empty --no-verify -m "$REF ($SHA)" || die "cannot commit the copy in $DIR"
    printf '%s\n' "$SHA" > "$D/.git/$MARK"
    for f in ${OVERLAYS[@]+"${OVERLAYS[@]}"}; do
      rel="${f#"$TOP"/}"
      mkdir -p "$D/$(dirname "$rel")" && cp -p "$TOP/$rel" "$D/$rel" || die "cannot copy the overlay $rel"
    done
    echo "$D"
    echo "Copy of $REF ($(git rev-parse --short "$SHA")): ${#LINKS[@]} ignored entr$([ ${#LINKS[@]} = 1 ] && echo y || echo ies) linked, ${#OVERLAYS[@]} overlay file(s)." >&2
    ;;
  run)
    DIR="${1:-}"; [ -n "$DIR" ] || usage; shift
    LABEL=""; TO=600
    while [ $# -gt 0 ]; do
      case "$1" in
        --label) [ -n "${2:-}" ] || die "--label needs a value"; LABEL="$2"; shift 2;;
        --timeout) [ -n "${2:-}" ] || die "--timeout needs a value"; TO="$2"; shift 2;;
        --) shift; break;;
        *) usage;;
      esac
    done
    [ $# -gt 0 ] || die "no command after --"
    case "$LABEL" in ''|*[!A-Za-z0-9._-]*|.*) die "--label must be letters, digits, '.', '_' or '-' (not starting with '.')";; esac
    case "$TO" in ''|*[!0-9]*|0) die "--timeout must be a positive number of seconds";; esac
    D="$(abs_dir "$DIR")" || die "no such directory: $DIR"
    is_copy "$D" || die "$DIR is not a copy made by crosscheck.sh tree"
    LOGF="$D.$LABEL.log"; T="$(mktemp -d "${TMPDIR:-/tmp}/orca-crosscheck.XXXXXX")" || die "cannot create a temporary folder"
    trap 'rm -rf "$T"' EXIT
    START="$(date +%s)"
    ( cd "$D" && exec "$@" ) > "$LOGF" 2>&1 < /dev/null & pid=$!
    ( n=0; while [ ! -e "$T/stop" ] && [ "$n" -lt $((TO * 10)) ]; do sleep 0.1; n=$((n + 1)); done; [ -e "$T/stop" ] || { : > "$T/to"; kill_tree $pid; } ) > /dev/null 2>&1 & sl=$!
    wait $pid 2>/dev/null; RC=$?
    : > "$T/stop"; wait $sl 2>/dev/null
    TIMED=false; [ -f "$T/to" ] && TIMED=true
    jq -nc --arg label "$LABEL" --arg dir "$D" --argjson exit "$RC" --argjson seconds "$(( $(date +%s) - START ))" --argjson timedOut "$TIMED" --arg log "$LOGF" \
      '{label: $label, dir: $dir, exit: $exit, seconds: $seconds, timedOut: $timedOut, log: $log}'
    ;;
  export)
    DIR="${1:-}"; [ -n "$DIR" ] || usage; shift
    SPECS=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --only|--except)
          p="${2:-}"; [ -n "$p" ] || die "$1 needs a path"
          case "$p" in /*|:*|*'\'*) die "$1 takes a path of the project, relative and literal: $p";; esac
          case "/${p%/}/" in */../*|*/./*) die "$1 path must not contain . or ..: $p";; esac
          if [ "$1" = --only ]; then SPECS+=(":(literal)$p"); else SPECS+=(":(exclude,literal)$p"); fi
          shift 2;;
        *) usage;;
      esac
    done
    D="$(abs_dir "$DIR")" || die "no such directory: $DIR"
    is_copy "$D" || die "$DIR is not a copy made by crosscheck.sh tree"
    git -C "$D" add -A || die "cannot read the changes of $DIR"
    git -C "$D" diff --cached --binary HEAD -- ${SPECS[@]+"${SPECS[@]}"} || die "cannot export the changes of $DIR"
    ;;
  apply)
    DIR="${1:-}"; PATCH="${2:-}"; [ -n "$DIR" ] && [ -n "$PATCH" ] && [ $# = 2 ] || usage
    D="$(abs_dir "$DIR")" || die "no such directory: $DIR"
    is_copy "$D" || die "$DIR is not a copy made by crosscheck.sh tree"
    [ -f "$PATCH" ] && [ -r "$PATCH" ] || die "no such patch file: $PATCH"
    PD="$(abs_dir "$(dirname "$PATCH")")" && PATCH="$PD/$(basename "$PATCH")"
    if [ ! -s "$PATCH" ]; then echo "crosscheck.sh: $PATCH is empty: nothing applied" >&2; exit 0; fi
    git -C "$D" apply --binary "$PATCH" || die "the patch does not apply to $DIR (nothing was changed)"
    echo "Applied $(basename "$PATCH") to $D" >&2
    ;;
  -h|--help) sed -n 2,16p "$0"; exit 0;;
  *) usage;;
esac
