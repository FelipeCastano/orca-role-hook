#!/usr/bin/env bash
# Compares two timing logs of tests/smoke.sh (SMOKE_TIMING_LOG): per section the seconds in A, in B and B-A.
# Usage: tests/timing-compare.sh <log A> <log B>   (e.g. main's run as A, the branch's as B)
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "timing-compare.sh: usage: tests/timing-compare.sh <log A> <log B>" >&2
  exit 2
fi
for f in "$1" "$2"; do
  first=""
  if [ -f "$f" ] && [ -r "$f" ]; then
    IFS= read -r first < "$f" || true
  fi
  case "$first" in
    "# smoke.sh timings"*) ;;
    *) echo "timing-compare.sh: $f is not a smoke.sh timing log" >&2; exit 2 ;;
  esac
done

awk -F'\t' '
function diff(a, b) {
  if (a == "-" || b == "-") return "-"
  d = b - a
  return (d > 0) ? "+" d : d ""
}
FNR == 1 { f++ }
$1 == "section" && NF >= 3 {
  if (f == 1) { sa[$2] = $3; if (!(($2) in ia)) { ia[$2] = 1; ordA[++na] = $2 } }
  else { sb[$2] = $3; if (!(($2) in ib)) { ib[$2] = 1; ordB[++nb] = $2 } }
}
$1 == "total" && NF >= 2 { if (f == 1) ta = $2; else tb = $2 }
END {
  print "section\tA\tB\tB-A"
  for (i = 1; i <= nb; i++) {
    n = ordB[i]; a = (n in sa) ? sa[n] : "-"
    print n "\t" a "\t" sb[n] "\t" diff(a, sb[n])
  }
  for (i = 1; i <= na; i++) {
    n = ordA[i]
    if (!(n in sb)) print n "\t" sa[n] "\t-\t-"
  }
  if (ta == "") ta = "-"
  if (tb == "") tb = "-"
  print "total\t" ta "\t" tb "\t" diff(ta, tb)
}' "$1" "$2"
