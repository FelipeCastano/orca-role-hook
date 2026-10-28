#!/usr/bin/env bash
# Usage metrics of the kit's Claude Code sessions, read from the transcripts (bin/usage_metrics.py does the work).
# Usage:  usage-metrics.sh --once
#         usage-metrics.sh --report [--task <t>] [--since <YYYY-MM-DD>] [--json]
#   --once    one pass: reads the new bytes of ~/.claude/projects/*/*.jsonl (the kit's sessions only), updates $KIT/metrics/state.json and appends the
#             changed sessions to $KIT/metrics/sessions-<day>.jsonl. Prints nothing; errors go to $KIT/metrics/usage-metrics.log. It does nothing when
#             settings.metrics.enabled is false in the global config ($KIT/config.json over config.default.json), and exits at once when another pass runs.
#   --report  totals from the store per task, role and model (tokens by type, cost, cost by type, cache savings, sessions); --since keeps the
#             sessions whose last line is on or after that date.
# The line format of the store is documented in bin/usage_metrics.py. Needs python3 >= 3.9.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; export KIT
case "${1:-}" in
  --once|--report) ;;
  -h|--help) sed -n 2,11p "$0"; exit 0;;
  *) echo "usage-metrics.sh: use --once or --report (see --help)" >&2; exit 2;;
esac
PY="${ORCA_ROLES_PYTHON:-python3}"
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  echo "usage-metrics.sh: python3 >= 3.9 is needed" >&2
  if [ "$1" = --once ] && mkdir -p "$KIT/metrics" 2>/dev/null; then printf '%s python3 >= 3.9 not found\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$KIT/metrics/usage-metrics.log" 2>/dev/null; fi
  exit 1
fi
exec "$PY" -I "$(cd "$(dirname "$0")" && pwd)/usage_metrics.py" "$@"
