#!/usr/bin/env bash
# Usage metrics of the kit's Claude Code sessions, read from the transcripts (bin/usage_metrics.py does the work).
# Usage:  usage-metrics.sh --once
#         usage-metrics.sh --report [--task <t>] [--since <YYYY-MM-DD>] [--json]
#         usage-metrics.sh --backfill --since <ISO time|YYYY-MM-DD> [--until <ISO time>] [--task <t>] [--dry-run] [--yes]
#   --once    one pass: reads the new bytes of ~/.claude/projects/*/*.jsonl (the kit's sessions only), updates $KIT/metrics/state.json and appends the
#             changed sessions to $KIT/metrics/sessions-<day>.jsonl. Prints nothing; errors go to $KIT/metrics/usage-metrics.log. It does nothing when
#             settings.metrics.enabled is false in the global config ($KIT/config.json over config.default.json), and exits at once when another pass runs.
#   --report  totals from the store per task, role and model (tokens by type, cost, cost by type, cache savings, sessions); --since keeps the
#             sessions whose last line is on or after that date.
#   --backfill  never automatic. Builds an OpenMetrics file ($KIT/metrics/backfill-<ts>.om) with the series --once pushes, for the kit's sessions from --since
#             until the start of Prometheus's head block (and before each session's first live push), checks it with promtool in the Prometheus container
#             (--dry-run stops there). Without --dry-run it needs --yes (ask the user first): it stops Prometheus with docker compose, backs the volume up to
#             ~/prometheus-backups/, starts it, imports the blocks with promtool and prints how to undo. The container is found by its image (prom/prometheus);
#             settings.metrics.prometheusContainer overrides.
# The line format of the store is documented in bin/usage_metrics.py. Needs python3 >= 3.9.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; export KIT
case "${1:-}" in
  --once|--report|--backfill) ;;
  -h|--help) sed -n 2,18p "$0"; exit 0;;
  *) echo "usage-metrics.sh: use --once, --report or --backfill (see --help)" >&2; exit 2;;
esac
PY="${ORCA_ROLES_PYTHON:-python3}"
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  echo "usage-metrics.sh: python3 >= 3.9 is needed" >&2
  if [ "$1" = --once ] && mkdir -p "$KIT/metrics" 2>/dev/null; then printf '%s python3 >= 3.9 not found\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$KIT/metrics/usage-metrics.log" 2>/dev/null; fi
  exit 1
fi
exec "$PY" -I "$(cd "$(dirname "$0")" && pwd)/usage_metrics.py" "$@"
