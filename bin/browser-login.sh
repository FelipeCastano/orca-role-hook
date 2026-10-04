#!/usr/bin/env bash
# Signs in to the application ONCE with a visible browser and saves the session (cookies and localStorage)
# so the Visual-Tester reuses it in headless mode.
# Usage (from the worktree or the project's repo):  browser-login.sh <url> [project-name]
# The session is saved in ~/.orca-roles/browser/<project>.json (by default, the name of the main repo's folder).
set -euo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
URL="${1:-}"; [ -n "$URL" ] || { sed -n 2,5p "$0" >&2; exit 1; }
PROJ="${2:-$(project_name .)}"
STATE="$KIT/browser/$PROJ.json"; mkdir -p "$KIT/browser"
command -v npx >/dev/null || { echo "ERROR: npx (Node) is missing." >&2; exit 1; }
echo "Project: $PROJ"
echo "A browser will open at $URL. Sign in (including MFA) and, once you see the application loaded, CLOSE the browser window."
echo "The session will be saved in $STATE"
npx -y playwright open --save-storage="$STATE" "$URL" || {
  echo "Could not open the browser. If it is the first time, install Chromium: npx playwright install chromium" >&2; exit 1; }
if jq -e '((.cookies // []) | length) + ((.origins // []) | length) > 0' "$STATE" >/dev/null 2>&1; then
  echo "Session saved: $(jq -r '"\((.cookies // []) | length) cookies, \((.origins // []) | length) origins with localStorage"' "$STATE")."
  echo "The Visual-Tester will use it the next time its tab starts (or after cleaning it with clean.sh)."
else
  echo "Warning: the saved session is empty. Did you close the browser before finishing the login?" >&2; exit 1
fi
