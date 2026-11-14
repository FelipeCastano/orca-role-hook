#!/usr/bin/env bash
# Checks that every section listed by tests/smoke.sh --list is named by exactly one `sections: "..."` line of a CI workflow.
# Usage: tests/ci-shards.sh [<workflow file>]   (default: .github/workflows/ci.yml under the repo this script is in)
set -euo pipefail
if [ "$#" -gt 1 ]; then
  echo "ci-shards.sh: usage: tests/ci-shards.sh [<workflow file>]" >&2
  exit 2
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
wf="${1:-$repo/.github/workflows/ci.yml}"
if [ ! -f "$wf" ] || [ ! -r "$wf" ]; then
  echo "ci-shards.sh: cannot read $wf" >&2
  exit 2
fi
sections="$(bash "$repo/tests/smoke.sh" --list)"
shard_lines="$(grep -E '^ *sections: "[^"]*"$' "$wf" || true)"
if [ -z "$shard_lines" ]; then
  echo "ci-shards.sh: no shard lists (sections: \"...\") in $wf" >&2
  exit 1
fi
values=()
while IFS= read -r line; do
  value="${line#*sections: \"}"
  values[${#values[@]}]="${value%\"}"
done <<< "$shard_lines"
K="${#values[@]}"
S=0
problems=""
for name in $sections; do
  S=$((S + 1))
  n=0
  for value in "${values[@]}"; do
    for token in $value; do
      if [ "$token" = "$name" ]; then n=$((n + 1)); break; fi
    done
  done
  if [ "$n" = 0 ]; then problems="$problems$name	ci-shards.sh: section in no shard: $name"$'\n'; fi
  if [ "$n" -gt 1 ]; then problems="$problems$name	ci-shards.sh: section in more than one shard: $name"$'\n'; fi
done
for value in "${values[@]}"; do
  for token in $value; do
    known=0
    for name in $sections; do
      if [ "$token" = "$name" ]; then known=1; break; fi
    done
    if [ "$known" = 0 ]; then problems="$problems$token	ci-shards.sh: unknown section in a shard: $token"$'\n'; fi
  done
done
if [ -n "$problems" ]; then
  printf '%s' "$problems" | LC_ALL=C sort -u | cut -f2- >&2
  exit 1
fi
echo "ci-shards.sh: every section runs in exactly one shard ($S sections, $K shards)."
