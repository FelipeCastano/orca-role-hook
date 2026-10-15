#!/usr/bin/env bash
# Runs an E2E flow (a Playwright script the E2E-Tester wrote) in the kit's pinned stack, from the worktree.
# Usage:  e2e-run.sh <flow> [--as <identity>] [--timeout <seconds>] [--list] [-- key=value ...]
#   <flow>      a folder under <e2eDir>/ (default qa-e2e) with at least one *.flow.ts or *.flow.js
#   --as        the saved identity whose session the flow starts with (see browser-login.sh); default: the default identity if saved
#   --timeout   per test, in seconds (default 60); the whole run is limited to timeout x flow files x 5 (at least 300 s)
#   --list      only lists the tests (playwright test --list): no browser, nothing runs, no session needed
#   key=value   inputs for the flow, read from JSON.parse(process.env.E2E_PARAMS || '{}')
# Evidence goes to <evidenceDir>/<flow>/ (report.json, and result.json if the flow writes it). Exit: the status of playwright;
# 1 usage or setup error; 2 the stack or the identity's session is not ready.
# Test hooks: KIT (default ~/.orca-roles), E2E_PLAYWRIGHT (default $KIT/pw/node_modules/.bin/playwright).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; export KIT
usage() { sed -n 2,10p "$0" >&2; exit 1; }

FLOW=""; IDENT=""; HAVE_AS=0; TSEC=60; LIST=0; PAIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --as) [ $# -ge 2 ] || { echo "ERROR: --as needs an identity." >&2; exit 1; }; IDENT="$2"; HAVE_AS=1; shift 2;;
    --timeout) [ $# -ge 2 ] || { echo "ERROR: --timeout needs seconds." >&2; exit 1; }; TSEC="$2"; shift 2;;
    --list) LIST=1; shift;;
    --) shift; PAIRS=("$@"); break;;
    -*) usage;;
    *) [ -z "$FLOW" ] || usage; FLOW="$1"; shift;;
  esac
done
[ -n "$FLOW" ] || usage
case "$TSEC" in ''|*[!0-9]*) echo "ERROR: --timeout must be a positive whole number of seconds." >&2; exit 1;; esac
[ "$((10#$TSEC))" -gt 0 ] || { echo "ERROR: --timeout must be a positive whole number of seconds." >&2; exit 1; }
TSEC="$((10#$TSEC))"
case "$FLOW" in ''|.*|*/*|*[!A-Za-z0-9._-]*) echo "ERROR: the flow is a folder name (letters, digits, '.', '_', '-'), not a path: '$FLOW'." >&2; exit 1;; esac

# shellcheck source=/dev/null
. "$KIT/bin/lib.sh"
WT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run e2e-run.sh from the project's worktree." >&2; exit 1; }
CFG="$(mktemp "${TMPDIR:-/tmp}/orca-roles-e2e.XXXXXX")" || exit 1
trap 'rm -f "$CFG"' EXIT
merged_config "$WT" > "$CFG" || { echo "ERROR: cannot read the effective configuration." >&2; exit 1; }
E2EDIR="$(jq -r '.roles["e2e-tester"].params.e2eDir // "qa-e2e"' "$CFG")"
EVID="$(jq -r '.roles["e2e-tester"].params.evidenceDir // "qa-evidence"' "$CFG")"

FLOWDIR="$WT/$E2EDIR/$FLOW"
[ -d "$FLOWDIR" ] || { echo "ERROR: the flow folder $FLOWDIR does not exist." >&2; exit 1; }
NFILES="$(find "$FLOWDIR" -maxdepth 1 -type f \( -name '*.flow.ts' -o -name '*.flow.js' \) | wc -l | tr -d ' ')"
[ "$NFILES" -gt 0 ] || { echo "ERROR: $FLOWDIR has no *.flow.ts or *.flow.js file." >&2; exit 1; }

"$KIT/bin/e2e-browser.sh" check || exit 2

PW="${E2E_PLAYWRIGHT:-$KIT/pw/node_modules/.bin/playwright}"
LINK="$WT/$E2EDIR/node_modules"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "ERROR: $LINK is a real file or folder; the kit needs a link there to its pinned @playwright/test. Remove it (never npm install inside $E2EDIR) and run again." >&2
  exit 1
fi
ln -sfn "$KIT/pw/node_modules" "$LINK" || { echo "ERROR: cannot link $LINK." >&2; exit 1; }
[ -f "$WT/$E2EDIR/package.json" ] || printf '{"private": true, "type": "commonjs"}\n' > "$WT/$E2EDIR/package.json"

PROJ="$(project_name "$WT")"
migrate_session "$PROJ"
STATE=""
has_session() {  # a readable JSON file with at least one cookie or origin
  [ -f "$1" ] && jq -e '((.cookies // []) | length) + ((.origins // []) | length) > 0' "$1" >/dev/null 2>&1
}
if [ "$LIST" = 1 ]; then
  STATE=""
elif [ "$HAVE_AS" = 1 ]; then
  STATE="$(session_file "$PROJ" "$IDENT")" || exit 1
  if ! has_session "$STATE"; then
    echo "ERROR: no saved session for identity '$IDENT' of project '$PROJ' ($STATE)." >&2
    # shellcheck disable=SC2088
    echo "Login: ~/.orca-roles/bin/browser-login.sh <url>$([ "$IDENT" = default ] || echo " --as $IDENT")" >&2
    exit 2
  fi
else
  STATE="$(session_file "$PROJ")" || exit 1
  has_session "$STATE" || STATE=""
fi

PARAMS='{}'
for pair in ${PAIRS[@]+"${PAIRS[@]}"}; do
  case "$pair" in
    [A-Za-z_]*=*) ;;
    *) echo "ERROR: malformed parameter '$pair': use key=value." >&2; exit 1;;
  esac
  PARAMS="$(printf '%s' "$PARAMS" | jq -c --arg k "${pair%%=*}" --arg v "${pair#*=}" '. + {($k): $v}')" || exit 1
done

EVIDDIR="$WT/$EVID/$FLOW"
if [ "$LIST" = 1 ]; then
  E2E_FLOW_DIR="$FLOWDIR" E2E_EVIDENCE_DIR="$EVIDDIR" E2E_TIMEOUT_MS="$((TSEC * 1000))" E2E_PARAMS="$PARAMS" E2E_STORAGE_STATE="" \
    PLAYWRIGHT_BROWSERS_PATH="$KIT/browsers" \
    "$PW" test --config "$KIT/pw/e2e.config.js" --list --reporter=list
  exit $?
fi
mkdir -p "$EVIDDIR" || exit 1
TMS=$((TSEC * 1000))
GMS=$((TMS * NFILES * 5)); [ "$GMS" -ge 300000 ] || GMS=300000

E2E_FLOW_DIR="$FLOWDIR" E2E_EVIDENCE_DIR="$EVIDDIR" E2E_TIMEOUT_MS="$TMS" E2E_PARAMS="$PARAMS" E2E_STORAGE_STATE="$STATE" \
  PLAYWRIGHT_BROWSERS_PATH="$KIT/browsers" \
  "$PW" test --config "$KIT/pw/e2e.config.js" --global-timeout "$GMS"
RC=$?
echo "Evidence: $EVIDDIR"
echo "report.json: $EVIDDIR/report.json"
[ ! -f "$EVIDDIR/result.json" ] || echo "result.json: $EVIDDIR/result.json"
exit "$RC"
