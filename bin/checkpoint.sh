#!/usr/bin/env bash
# Records the worktree as it is now (tracked and untracked files, honouring .gitignore) as a commit under refs/orca-roles/checkpoints/,
# without touching HEAD, the index, the branch or the working tree, so workers can diff a round against the previous one.
# Usage (from the worktree):  checkpoint.sh [--force] <step> <n>   |   checkpoint.sh --list [<step>]
#                             checkpoint.sh --clear <step>   |   checkpoint.sh --clear-all
# <step> is [a-z0-9-]+ (starting with a letter or digit) and <n> an integer; the ref is refs/orca-roles/checkpoints/<worktree id>/<step>-c<n>.
set -uo pipefail
NS=refs/orca-roles/checkpoints
die() { echo "checkpoint.sh: $*" >&2; exit 1; }
usage() { sed -n 4,5p "$0" >&2; exit 1; }
valid_step() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
valid_n() { [[ "$1" =~ ^(0|[1-9][0-9]{0,8})$ ]]; }

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this from inside the worktree"
GD="$(git rev-parse --absolute-git-dir)" || die "cannot find the git dir"
# refs are shared by every worktree of the repo: the id is the folder name plus a hash of this worktree's git dir
H="$(printf '%s' "$GD" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | cut -d' ' -f1 | cut -c1-10)"
WT="$(basename "$TOP" | tr -c 'A-Za-z0-9\n-' '-' | sed 's/^-*//')"; WT="${WT:-wt}-$H"
BASE="$NS/$WT"

list_step() {  # <step|""> → ref names, ordered by n
  local r s
  git for-each-ref --format='%(refname)' "$BASE/" | while IFS= read -r r; do
    s="${r#"$BASE"/}"
    if [ -z "$1" ] || [[ "$s" =~ ^$1-c[0-9]+$ ]]; then echo "$r"; fi
  done | sort -t c -k 2 -V 2>/dev/null || true
}
seq_of() {  # <ref> → creation sequence number recorded in its message (0 if none)
  local k; k="$(git log -1 --format=%s "$1" 2>/dev/null | sed -n 's/^.* seq \([0-9][0-9]*\)$/\1/p')"
  echo "${k:-0}"
}
max_seq() { local r m=0 k; while IFS= read -r r; do [ -n "$r" ] || continue; k="$(seq_of "$r")"; [ "$k" -gt "$m" ] && m="$k"; done < <(list_step ""); echo "$m"; }
diff_hints() {  # <step> <n>
  local ref="$BASE/$1-c$2" prev="$BASE/$1-c$(($2 - 1))" r k best="" bk=-1 first
  if [ "$1" = set ]; then
    first="Whole set since the branch base (HEAD):  git diff HEAD $ref"
  else
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      [[ "${r#"$BASE"/}" =~ ^$1-c[0-9]+$ ]] && continue
      k="$(seq_of "$r")"; if [ "$k" -gt "$bk" ]; then bk="$k"; best="$r"; fi
    done < <(list_step "")
    first="Whole step since ${best:-HEAD} (the first brief):  git diff ${best:-HEAD} $ref"
  fi
  echo "$first"
  if [ "$2" -gt 0 ] && git show-ref --verify --quiet "$prev"; then echo "Since the previous checkpoint:             git diff $prev $ref"; fi
}

case "${1:-}" in
  --list)
    [ $# -le 2 ] || usage
    [ -z "${2:-}" ] || valid_step "$2" || die "invalid step '$2': use [a-z0-9-]+"
    list_step "${2:-}" | while IFS= read -r r; do echo "$r $(git rev-parse --short "$r") $(git log -1 --format=%cd --date=iso "$r")"; done
    exit 0 ;;
  --clear-all)
    [ $# = 1 ] || usage
    N=0; while IFS= read -r r; do [ -n "$r" ] || continue; git update-ref -d "$r" && N=$((N + 1)); done < <(list_step "")
    echo "Deleted $N checkpoint(s)"; exit 0 ;;
  --clear)
    [ $# = 2 ] || usage
    valid_step "$2" || die "invalid step '$2': use [a-z0-9-]+"
    N=0; while IFS= read -r r; do [ -n "$r" ] || continue; git update-ref -d "$r" && N=$((N + 1)); done < <(list_step "$2")
    echo "Deleted $N checkpoint(s) of step $2"; exit 0 ;;
esac

FORCE=0; [ "${1:-}" = --force ] && { FORCE=1; shift; }
[ $# = 2 ] || usage
STEP="$1"; N="$2"
valid_step "$STEP" || die "invalid step '$STEP': use [a-z0-9-]+"
valid_n "$N" || die "invalid n '$N': use a non-negative integer without leading zeros"
REF="$BASE/$STEP-c$N"
git check-ref-format "$REF" || die "invalid ref $REF"
if [ "$FORCE" = 0 ] && git show-ref --verify --quiet "$REF"; then die "$REF already exists (use --force to overwrite it)"; fi

T="$(mktemp -d "${TMPDIR:-/tmp}/orca-checkpoint.XXXXXX")" || die "cannot create a temporary folder"
trap 'rm -rf "$T"' EXIT
IDX="$(git rev-parse --path-format=absolute --git-path index)"
[ -f "$IDX" ] && cp "$IDX" "$T/index"
cd "$TOP" || die "cannot enter $TOP"
export GIT_INDEX_FILE="$T/index"
STALE="$(git ls-files -v | grep -E '^[a-zS] ' | cut -c3-)"
if [ -n "$STALE" ]; then
  echo "Warning: $(printf '%s\n' "$STALE" | wc -l | tr -d ' ') file(s) marked assume-unchanged or skip-worktree are recorded as in the index, not as in the working tree: $(printf '%s\n' "$STALE" | head -5 | tr '\n' ' ' | sed 's/ $//')" >&2
fi
git add -A >/dev/null || die "git add failed; nothing written"
TREE="$(git write-tree)" || die "git write-tree failed; nothing written"
unset GIT_INDEX_FILE
PARENT=(); git rev-parse --verify -q HEAD >/dev/null && PARENT=(-p HEAD)
export GIT_AUTHOR_NAME=orca-roles GIT_AUTHOR_EMAIL=orca-roles@localhost GIT_COMMITTER_NAME=orca-roles GIT_COMMITTER_EMAIL=orca-roles@localhost
SEQ=$(( $(max_seq) + 1 ))
C="$(git commit-tree "$TREE" ${PARENT[@]+"${PARENT[@]}"} -m "checkpoint $STEP-c$N seq $SEQ")" || die "git commit-tree failed; nothing written"
if [ "$FORCE" = 1 ]; then git update-ref "$REF" "$C"; else git update-ref "$REF" "$C" ""; fi || die "could not write $REF"
echo "$REF"
diff_hints "$STEP" "$N"
