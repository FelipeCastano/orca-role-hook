#!/usr/bin/env bash
# Live checks on macOS with Claude Code: what the smoke tests cannot cover (see docs/live-checks.md).
# Usage (from an Orca terminal of this checkout, with this checkout installed: ./install.sh):  tests/live/mac.sh
# Run it once; it ends asking for a real restart of Orca. Run the same command again after the restart to finish.
# Report: ~/orca-live-checks/report-mac.md. To start over: rm ~/orca-live-checks/state-mac
set -uo pipefail
. "$(dirname "$0")/lib.sh"
live_is_wsl && { echo "This is WSL: run tests/live/wsl.sh." >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "This script is for macOS." >&2; exit 1; }
live_main mac
