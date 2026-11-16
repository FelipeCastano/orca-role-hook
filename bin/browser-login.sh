#!/usr/bin/env bash
# Signs in to the application ONCE with a visible browser and saves the session (cookies and localStorage)
# so the E2E-Tester reuses it in headless mode. Only the user runs this: the E2E-Tester never logs in or saves.
# Usage (from the worktree or the project's repo):  browser-login.sh <url> [project-name] [--as <identity>]
# The session is saved in ~/.orca-roles/browser/<project>/<identity>.json (by default, the name of the main repo's folder and the
# identity "default"; an identity is lowercase letters, digits and hyphens). It opens the kit's pinned Chromium (see e2e-browser.sh).
set -euo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
URL="" PROJ="" IDENT=default
while [ $# -gt 0 ]; do
  case "$1" in
    --as) [ $# -ge 2 ] || { echo "ERROR: --as needs an identity." >&2; exit 1; }; IDENT="$2"; shift 2;;
    *) if [ -z "$URL" ]; then URL="$1"; elif [ -z "$PROJ" ]; then PROJ="$1"; else sed -n 2,6p "$0" >&2; exit 1; fi; shift;;
  esac
done
[ -n "$URL" ] || { sed -n 2,6p "$0" >&2; exit 1; }
[ -n "$PROJ" ] || PROJ="$(project_name .)"
STATE="$(session_file "$PROJ" "$IDENT")" || exit 1
PW="$KIT/pw/node_modules/.bin/playwright"
export KIT
CHK="$("$KIT/bin/e2e-browser.sh" check 2>&1)" || { echo "$CHK" >&2; exit 2; }
[ -x "$PW" ] || { echo "ERROR: $PW is missing. Fix: $KIT/bin/e2e-browser.sh install" >&2; exit 2; }
# A Linux machine with no display starts Chromium nowhere: say so before it fails with an unrelated error.
if [ "$(uname -s)" = Linux ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "ERROR: no display for the browser: DISPLAY and WAYLAND_DISPLAY are not set. On WSL, enable WSLg (wsl --update, then wsl --shutdown) or run browser-login.sh from a terminal that has a display." >&2
  exit 2
fi
migrate_session "$PROJ"
mkdir -p "$(dirname "$STATE")"
TMP="$STATE.tmp.$$"; rm -f "$TMP" "$TMP.err"; trap 'rm -f "$TMP" "$TMP.err"' EXIT
echo "Project: $PROJ"
echo "Identity: $IDENT"
echo "A browser will open at $URL. Sign in (including MFA) and, once you see the application loaded, CLOSE the browser window."
echo "The session will be saved in $STATE"
# A run that saves nothing within a few seconds is a browser that never started (no display, an immediate crash), not an unfinished login.
MIN="${ORCA_ROLES_BROWSER_MIN_SECONDS-5}"; case "$MIN" in ''|*[!0-9]*) MIN=5;; esac
T0=$SECONDS
if PLAYWRIGHT_BROWSERS_PATH="$KIT/browsers" "$PW" open --save-storage="$TMP" "$URL" 2> "$TMP.err"; then PWC=0; else PWC=$?; fi
TOOK=$((SECONDS - T0))
[ ! -s "$TMP.err" ] || cat "$TMP.err" >&2
if [ ! -f "$TMP" ] && { [ "$PWC" -ne 0 ] || [ "$TOOK" -lt "$MIN" ]; }; then
  # the loader's text names the real cause: Playwright's last line can be a benign dbus error or "<gracefully close end>"
  LAST="$(awk '{ sub(/\r$/, "") }
    !loader && /error while loading shared libraries|cannot open shared object file/ { loader = $0 }
    !err && /\[err\]/ { err = $0 }
    NF { last = $0 }
    END { print (loader != "" ? loader : err != "" ? err : last) }' "$TMP.err")"
  [ -n "$LAST" ] || LAST="no output"
  echo "ERROR: the browser did not start or closed at once (playwright exited with $PWC after $TOOK s): $LAST. Nothing was saved." >&2
  if [ -f "$STATE" ]; then echo "The previous session ($STATE) is unchanged." >&2; fi
  exit 2
fi
if [ -f "$TMP" ] && session_matches "$TMP" "$URL"; then
  mv -f "$TMP" "$STATE"
  echo "Session saved: $(jq -r '"\((.cookies // []) | length) cookies, \((.origins // []) | length) origins"' "$STATE")."
  echo "The E2E-Tester's next browser session and the flows run with e2e-run.sh will use it; nothing needs restarting."
else
  echo "Nothing was saved for $(url_host_origin "$URL" | sed -n 1p): the browser stored no cookie for that host (did you finish the login?)." >&2
  if [ -f "$STATE" ]; then echo "The previous session ($STATE) is unchanged." >&2; fi
  exit 1
fi
