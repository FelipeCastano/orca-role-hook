#!/usr/bin/env bash
# Brings the worktree's branch up to the remote base before a new request is planned, only when that is safe (fetch + fast-forward); otherwise
# it changes nothing and says why, so the local coordinator can ask the user or just inform. Never rebases, pulls, stashes, resets or checks out.
# Usage (from the worktree):  sync-base.sh [--base <branch>]      (the base is origin/HEAD, else main, else master)
# Exit: 0 up to date, fast-forwarded, or nothing to sync (no origin, no base found); 2 usage error or not a git worktree;
#       3 fetch failed or timed out (work goes on with the local copy); 4 behind and not changed.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
usage() { echo "Usage: sync-base.sh [--base <branch>]" >&2; exit 2; }

base=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n 4,6p "$0" | sed 's/^# //'; exit 0;;
    --base) [ $# -ge 2 ] && [ -n "$2" ] || usage; base="$2"; shift 2;;
    --base=?*) base="${1#--base=}"; shift;;
    *) usage;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: not a git worktree." >&2; exit 2; }
git remote get-url origin >/dev/null 2>&1 || { echo "No origin remote; nothing synced."; exit 0; }

if [ -z "$base" ]; then
  if b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then base="${b#origin/}"
  elif git show-ref --verify --quiet refs/remotes/origin/main; then base=main
  elif git show-ref --verify --quiet refs/remotes/origin/master; then base=master
  else echo "No base branch found on origin; nothing synced."; exit 0; fi
fi

if ! GIT_TERMINAL_PROMPT=0 bounded_run --quiet 60 sync-base git fetch --quiet origin "$base" 2>/dev/null; then
  echo "WARNING: could not fetch origin/$base; working on the local copy, which may be stale."; exit 3
fi

behind="$(git rev-list --count "HEAD..origin/$base" 2>/dev/null)" || behind=""
ahead="$(git rev-list --count "origin/$base..HEAD" 2>/dev/null)" || ahead=""
if [ -z "$behind" ] || [ -z "$ahead" ]; then echo "WARNING: could not fetch origin/$base; working on the local copy, which may be stale."; exit 3; fi

if [ "$behind" = 0 ]; then
  echo "Up to date with origin/$base ($(git rev-parse --short "origin/$base"))."; exit 0
fi

branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
dirty=0
[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=1

if [ "$ahead" = 0 ] && [ -n "$branch" ] && [ "$dirty" = 0 ]; then
  old="$(git rev-parse --short HEAD)"
  if git merge --ff-only --quiet "origin/$base"; then
    echo "Fast-forwarded $branch from $old to $(git rev-parse --short HEAD) (origin/$base, $behind commits)."; exit 0
  fi
  echo "Not changed."; exit 4
fi

if [ -z "$branch" ]; then state=detached; elif [ "$dirty" = 1 ]; then state=dirty; else state=clean; fi
echo "Behind origin/$base by $behind commits ($ahead local commits, tree $state); not changed. To bring them in: git merge origin/$base"
exit 4
