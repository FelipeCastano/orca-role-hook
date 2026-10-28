#!/usr/bin/env bash
# Branch names with the repo convention <type>/<KEY>-<slug> (e.g. feat/DEVGD-292-tax-classifier), without the user's name.
# Orca names a worktree's branch <git-user>/<name>; its CLI cannot set the branch, so the Planner proposes the name with the plan and renames the
# branch after the user's yes, before anything is pushed.
# Usage:  branch-name.sh --propose --type <feat|fix|chore|docs|refactor|test> --slug "<words>" [--key <KEY>]
#           prints <type>/<KEY>-<slug>, or <type>/<slug> without a key. The key is --key, else the worktree's Jira key (Orca's linked
#           ticket, else the branch, as launch.sh gets it), else the worktree folder's name when it looks like abc-123.
#         branch-name.sh --rename <name>      (from inside the worktree)
#           renames the CURRENT branch (git branch -m) only if the name is valid, HEAD is on a branch, it has no upstream, no remote has a
#           branch of that name, no other worktree has it checked out and <name> does not exist yet; else exit 1 with the reason.
# Exit: 0 ok, 1 not renamed, 2 bad usage.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
case "${1:-}" in -h|--help) sed -n 2,13p "$0"; exit 0;; esac
usage() { echo "usage: branch-name.sh --propose --type <feat|fix|chore|docs|refactor|test> --slug \"<words>\" [--key <KEY>] | --rename <name>" >&2; exit 2; }

propose() {
  local type="" slug="" key="" top cfg j lk
  while [ $# -gt 0 ]; do
    case "$1" in
      --type) [ $# -ge 2 ] || usage; type="$2"; shift 2;;
      --slug) [ $# -ge 2 ] || usage; slug="$2"; shift 2;;
      --key) [ $# -ge 2 ] || usage; key="$2"; shift 2;;
      *) usage;;
    esac
  done
  case "$type" in feat|fix|chore|docs|refactor|test) ;; *) echo "branch-name.sh: --type must be feat, fix, chore, docs, refactor or test" >&2; exit 2;; esac
  if [ -z "$key" ]; then
    cfg="$KIT/config.json"; [ -f "$cfg" ] || cfg="$KIT/config.default.json"
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || top="$PWD"
    j="$(worktree_jira "$top" "$cfg" 2>/dev/null | head -1)"
    [ -z "$j" ] || key="$j"
    if [ -z "$key" ]; then key="$(basename "$top" | grep -oE '^[a-z][a-z0-9]*-[0-9]+' | head -1)"; fi
  fi
  key="$(printf '%s' "$key" | tr 'a-z' 'A-Z')"
  slug="$(printf '%s' "$slug" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-*//' -e 's/-*$//')"
  if [ -n "$key" ]; then
    lk="$(printf '%s' "$key" | tr 'A-Z' 'a-z')-"
    case "$slug" in "$lk"*) slug="${slug#"$lk"}";; esac
  fi
  slug="$(printf '%s' "${slug:0:40}" | sed -e 's/-*$//')"
  [ -n "$slug" ] || { echo "branch-name.sh: the slug is empty after cleaning" >&2; exit 2; }
  if [ -n "$key" ]; then echo "$type/$key-$slug"; else echo "$type/$slug"; fi
}

rename() {
  local new="${1:-}" cur up r out here p
  [ -n "$new" ] && [ $# -eq 1 ] || usage
  no() { echo "branch-name.sh: not renamed: $1"; exit 1; }
  case "$new" in -*) no "invalid name";; esac
  git check-ref-format --branch "$new" >/dev/null 2>&1 || no "invalid name"
  cur="$(git symbolic-ref --short -q HEAD 2>/dev/null)" || no "detached HEAD"
  if [ "$cur" = "$new" ]; then echo "already $new"; exit 0; fi
  up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" && no "it tracks $up"
  for r in $(git remote 2>/dev/null); do
    if out="$(GIT_TERMINAL_PROMPT=0 run_limited 10 "ls-remote $r" git ls-remote --heads "$r" "refs/heads/$cur" 2>/dev/null)"; then
      [ -z "$out" ] || no "it exists on $r"
    else
      echo "branch-name.sh: could not check remote $r; renaming anyway"
    fi
  done
  here="$(git rev-parse --show-toplevel 2>/dev/null)"
  p="$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$cur" -v here="$here" '$1 == "worktree" { path = substr($0, 10) } $1 == "branch" && $2 == b && path != here { print path; exit }')"
  [ -z "$p" ] || no "checked out in $p"
  ! git show-ref --verify --quiet "refs/heads/$new" || no "$new already exists"
  git branch -m "$cur" "$new" >/dev/null 2>&1 || no "git branch -m failed"
  echo "renamed $cur -> $new"
}

case "${1:-}" in
  --propose) shift; propose "$@";;
  --rename) shift; rename "$@";;
  *) usage;;
esac
