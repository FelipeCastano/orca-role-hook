#!/usr/bin/env bash
# Checks that every section listed by tests/smoke.sh --list is named by exactly one `sections: "..."` line of each shard list in a CI workflow.
# A `sections:` line belongs to the nearest preceding job header (a line `  <job>:`); every job with shard lists must name every section exactly once.
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
groups="$(awk '
  /^  [A-Za-z0-9_-]+:$/ { job = $0; sub(/^  /, "", job); sub(/:$/, "", job); next }
  /^ *sections: "[^"]*"$/ {
    value = $0
    sub(/^ *sections: "/, "", value)
    sub(/"$/, "", value)
    if (job != "") print job "\t" value
  }' "$wf")"
if [ -z "$groups" ]; then
  echo "ci-shards.sh: no shard lists (sections: \"...\") in $wf" >&2
  exit 1
fi
jobs=()
counts=()
values=()
value_job=()
while IFS=$'\t' read -r job value; do
  idx=-1
  i=0
  while [ "$i" -lt "${#jobs[@]}" ]; do
    if [ "${jobs[$i]}" = "$job" ]; then idx="$i"; break; fi
    i=$((i + 1))
  done
  if [ "$idx" = -1 ]; then
    jobs[${#jobs[@]}]="$job"
    idx=$((${#jobs[@]} - 1))
    counts[$idx]=0
  fi
  counts[$idx]=$((counts[$idx] + 1))
  values[${#values[@]}]="$value"
  value_job[${#value_job[@]}]="$idx"
done <<< "$groups"
G="${#jobs[@]}"
if [ "$G" -lt 2 ]; then
  echo "ci-shards.sh: found $G shard list in $wf, at least 2 are required (the Ubuntu and the macOS shard lists)" >&2
  exit 1
fi
S=0
problems=""
for name in $sections; do
  S=$((S + 1))
  j=0
  while [ "$j" -lt "$G" ]; do
    n=0
    v=0
    while [ "$v" -lt "${#values[@]}" ]; do
      if [ "${value_job[$v]}" = "$j" ]; then
        for token in ${values[$v]}; do
          if [ "$token" = "$name" ]; then n=$((n + 1)); break; fi
        done
      fi
      v=$((v + 1))
    done
    if [ "$n" = 0 ]; then problems="$problems$name	ci-shards.sh: section in no shard of ${jobs[$j]}: $name"$'\n'; fi
    if [ "$n" -gt 1 ]; then problems="$problems$name	ci-shards.sh: section in more than one shard of ${jobs[$j]}: $name"$'\n'; fi
    j=$((j + 1))
  done
done
v=0
while [ "$v" -lt "${#values[@]}" ]; do
  for token in ${values[$v]}; do
    known=0
    for name in $sections; do
      if [ "$token" = "$name" ]; then known=1; break; fi
    done
    if [ "$known" = 0 ]; then problems="$problems$token	ci-shards.sh: unknown section in a shard of ${jobs[${value_job[$v]}]}: $token"$'\n'; fi
  done
  v=$((v + 1))
done
if [ -n "$problems" ]; then
  printf '%s' "$problems" | LC_ALL=C sort -u | cut -f2- >&2
  exit 1
fi
shard_list=""
j=0
while [ "$j" -lt "$G" ]; do
  shard_list="$shard_list${shard_list:+, }${counts[$j]}"
  j=$((j + 1))
done
echo "ci-shards.sh: every section runs in exactly one shard in each of $G shard lists ($S sections; shards: $shard_list)."
