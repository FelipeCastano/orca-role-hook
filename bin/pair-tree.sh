#!/usr/bin/env bash
# Pair trees: one detached git worktree per batch that runs in parallel, outside the worktree, for its Dev and Tester (see the local coordinator's "Parallel batches").
# Usage (from the worktree where the roles were opened):
#   pair-tree.sh create <batch> <start-ref>     makes the batch's tree at <start-ref>; prints its path (last line)
#   pair-tree.sh integrate <batch> <closing-ref> applies the batch's work (<start-ref>..<closing-ref>) to the worktree, unstaged; exit 4 on a conflict (nothing written)
#   pair-tree.sh remove [--force] <batch>        removes the batch's tree (--force: also when it was not integrated); its checkpoint refs stay
#   pair-tree.sh list                            one line per tree: batch, state, path, start
#   pair-tree.sh clear                           at set close: forgets every tree and deletes their checkpoint refs and patches
# Exit 0 done; 1 refused or failed (nothing changed); 4 integrate conflict.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
die() { echo "pair-tree.sh: $*" >&2; exit 1; }
usage() { sed -n 2,9p "$0" >&2; exit 1; }
case "${1:-}" in -h|--help) sed -n 2,9p "$0"; exit 0;; esac
CMD="${1:-}"; [ $# -gt 0 ] && shift
case "$CMD" in
  create|integrate) [ $# -eq 2 ] || usage;;
  remove) { [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$1" = --force ]; }; } || usage;;
  list|clear) [ $# -eq 0 ] || usage;;
  *) usage;;
esac

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this from inside the worktree"
GD="$(git rev-parse --absolute-git-dir)" || die "cannot find the git dir"
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" || die "cannot find the common git dir"
[ ! -e "$GD/orca-roles.pair" ] || die "this is a pair tree: run pair-tree.sh from the worktree where the roles were opened"
REG="$GD/orca-roles.pairs"
cd "$TOP" || die "cannot enter $TOP"
PAIRS="$(scratch_dir pairs)" || die "cannot compute the pair trees folder"

valid_batch() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
# the registry line of <batch> in state open or integrated (at most one exists)
active_line() { [ -f "$REG" ] || return 0; awk -F'\t' -v b="$1" '$1 == b && ($6 == "open" || $6 == "integrated") {print; exit}' "$REG"; }
set_state() {  # <batch> <k> <state>
  local t; t="$(mktemp "$GD/orca-roles.pairs.XXXXXX")" || die "cannot write the registry"
  awk -F'\t' -v OFS='\t' -v b="$1" -v k="$2" -v s="$3" '$1 == b && $2 == k {$6 = s} {print}' "$REG" > "$t" && mv "$t" "$REG" || { rm -f "$t"; die "cannot write the registry"; }
}
drop_tree() {  # <path>
  git worktree remove --force "$1" >/dev/null 2>&1
  [ ! -e "$1" ] && [ ! -L "$1" ] || rm -rf "$1"
  git worktree prune
}

case "$CMD" in
  create)
    B="$1"; REF="$2"
    valid_batch "$B" || die "invalid batch id: $B (lowercase letters, digits and hyphens)"
    SHA="$(git rev-parse --verify --quiet "$REF^{commit}")" || die "not a commit: $REF"
    L="$(active_line "$B")"
    [ -z "$L" ] || die "batch $B already has a pair tree: $(printf '%s' "$L" | cut -f3)"
    K=1
    if [ -f "$REG" ]; then K="$(awk -F'\t' -v b="$B" 'BEGIN {m = 0} $1 == b && $2 + 0 > m {m = $2 + 0} END {print m + 1}' "$REG")"; fi
    P="$PAIRS/$B-$K"
    [ ! -e "$P" ] && [ ! -L "$P" ] || die "$P already exists"
    SUBS="$(git -C "$TOP" submodule status 2>/dev/null | cut -c1 | grep -vc '^-$')"
    [ "${SUBS:-0}" = 0 ] || die "the worktree has initialised submodules, which a pair tree would not have: run this batch in the worktree"
    mkdir -p "$PAIRS" || die "cannot create $PAIRS"
    if ! git -c core.hooksPath=/dev/null worktree add --detach --quiet "$P" "$SHA" >/dev/null 2>&1; then
      drop_tree "$P"; die "git could not create the tree at $P"
    fi
    LINKED=(); N=0
    while IFS= read -r p; do [ -n "$p" ] && LINKED+=("$p"); done < <(link_ignored_entries "$TOP" "$P")
    for p in ${LINKED[@]+"${LINKED[@]}"}; do
      N=$((N + 1))
      why="$(link_back_reason "$TOP" "$p")"
      if [ -n "$why" ]; then
        drop_tree "$P"
        die "$p links back into the worktree, $why: tests in a pair tree would run the worktree's code; run this batch in the worktree"
      fi
    done
    mkdir -p "$COMMON/info"; touch "$COMMON/info/exclude"
    for p in ${LINKED[@]+"${LINKED[@]}"}; do
      grep -qxF "/$p" "$COMMON/info/exclude" || printf '/%s\n' "$p" >> "$COMMON/info/exclude"
    done
    PGD="$(git -C "$P" rev-parse --absolute-git-dir)"
    printf '%s\n' "$GD" > "$PGD/orca-roles.pair"
    PP="$(cd "$P" && pwd -P)"
    printf '%s\t%s\t%s\t%s\t%s\topen\n' "$B" "$K" "$PP" "$SHA" "$PGD" >> "$REG"
    echo "Pair tree of $B at $(git rev-parse --short "$SHA"): $N ignored entr$([ "$N" = 1 ] && echo y || echo ies) linked." >&2
    echo "$PP"
    ;;
  integrate)
    B="$1"; REF="$2"
    L="$(active_line "$B")"
    [ -n "$L" ] && [ "$(printf '%s' "$L" | cut -f6)" = open ] || die "batch $B has no open pair tree"
    K="$(printf '%s' "$L" | cut -f2)"; START="$(printf '%s' "$L" | cut -f4)"
    CSHA="$(git rev-parse --verify --quiet "$REF^{commit}")" || die "not a commit: $REF"
    BAK="$(find "$TOP" -name '*.orca-bak' -not -path '*/.git/*' 2>/dev/null | head -1)"
    [ -z "$BAK" ] || die "a mutation backup is in the worktree ($BAK): a code task is in flight here; integrate once it reports"
    mkdir -p "$PAIRS" || die "cannot create $PAIRS"
    PATCH="$PAIRS/$B-$K.patch"
    git diff --binary "$START" "$CSHA" > "$PATCH" || die "cannot write the patch $PATCH"
    if [ ! -s "$PATCH" ]; then
      set_state "$B" "$K" integrated
      echo "nothing to integrate for $B"
      exit 0
    fi
    if ! git -C "$TOP" apply --check "$PATCH" || ! git -C "$TOP" apply "$PATCH"; then
      echo "conflict $B: $PATCH"
      exit 4
    fi
    set_state "$B" "$K" integrated
    echo "integrated $B: $(git apply --numstat "$PATCH" | wc -l | tr -d ' ') file(s)"
    ;;
  remove)
    FORCE=0; [ "$1" = --force ] && { FORCE=1; shift; }
    B="$1"
    L="$(active_line "$B")"
    [ -n "$L" ] || die "batch $B has no pair tree to remove"
    [ "$FORCE" = 1 ] || [ "$(printf '%s' "$L" | cut -f6)" != open ] || die "batch $B was not integrated: its work would be lost (integrate it, or remove it with --force)"
    K="$(printf '%s' "$L" | cut -f2)"; TP="$(printf '%s' "$L" | cut -f3)"
    if [ -d "$TP" ]; then (cd "$TP" && "$KIT/bin/forget-trust.sh" >/dev/null 2>&1) || true; fi
    drop_tree "$TP"
    set_state "$B" "$K" removed
    echo "removed $B ($TP)"
    ;;
  list)
    [ -f "$REG" ] || exit 0
    awk -F'\t' -v OFS='\t' '{print $1, $6, $3, substr($4, 1, 12)}' "$REG"
    ;;
  clear)
    if [ ! -f "$REG" ]; then echo "cleared 0 pair tree(s)"; exit 0; fi
    BUSY="$(awk -F'\t' '$6 == "open" || $6 == "integrated" {printf "%s%s (%s)", sep, $1, $6; sep = ", "}' "$REG")"
    [ -z "$BUSY" ] || die "pair trees still in use: $BUSY: remove them first"
    N=0
    while IFS=$'\t' read -r b k path _ pgd _; do
      [ -n "$b" ] || continue
      N=$((N + 1))
      H="$(printf '%s' "$pgd" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | cut -d' ' -f1 | cut -c1-10)"
      WT="$(basename "$path" | tr -c 'A-Za-z0-9\n-' '-' | sed 's/^-*//')"; WT="${WT:-wt}-$H"
      while IFS= read -r r; do [ -n "$r" ] && git update-ref -d "$r"; done < <(git for-each-ref --format='%(refname)' "refs/orca-roles/checkpoints/$WT/")
      rm -f "$PAIRS/$b-$k.patch"
    done < "$REG"
    rm -f "$REG"
    echo "cleared $N pair tree(s)"
    ;;
esac
