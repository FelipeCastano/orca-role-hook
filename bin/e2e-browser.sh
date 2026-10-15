#!/usr/bin/env bash
# The E2E browser stack of the kit: the pinned Playwright packages in ~/.orca-roles/pw and their Chromium build in
# ~/.orca-roles/browsers. The Playwright MCP, browser-login.sh and the E2E scripts all use it.
# Usage:  e2e-browser.sh check     exit 0 if the stack is installed (no browser is started), 2 and the fix if not
#         e2e-browser.sh install   npm ci in ~/.orca-roles/pw, then installs the pinned Chromium (no sudo); ends with check
#         e2e-browser.sh session <base-url> [--as <identity>] [project]
#                                  reads the saved session (no browser is started); exit 0 ok, 3 missing, 4 no-session-for-host,
#                                  5 expired, 6 unknown (only session cookies); 1 usage; every non-zero prints the login command
# Test hooks: E2E_NPM (default npm), E2E_NODE (default node), KIT (default ~/.orca-roles).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"
NPM="${E2E_NPM:-npm}"; NODE="${E2E_NODE:-node}"
TREE="$KIT/pw"
export PLAYWRIGHT_BROWSERS_PATH="$KIT/browsers"
FIX="$KIT/bin/e2e-browser.sh install"

pinned() {  # $1 = package name → the version pinned in package.json (empty if none)
  jq -r --arg p "$1" '.dependencies[$p] // empty' "$TREE/package.json" 2>/dev/null
}

check() {
  local missing="" pkg want have exe dir
  if [ ! -f "$TREE/package.json" ]; then
    missing="$missing
  - $TREE/package.json (the kit's pinned packages)"
  else
    for pkg in @playwright/mcp @playwright/test; do
      want="$(pinned "$pkg")"
      have="$(jq -r '.version // empty' "$TREE/node_modules/$pkg/package.json" 2>/dev/null)"
      if [ -z "$have" ]; then missing="$missing
  - $pkg is not installed in $TREE/node_modules"
      elif [ "$have" != "$want" ]; then missing="$missing
  - $pkg is $have in $TREE/node_modules, the kit pins $want"; fi
    done
  fi
  exe=""
  if [ -d "$TREE/node_modules/playwright-core" ]; then
    exe="$("$NODE" -e 'console.log(require(process.argv[1]).chromium.executablePath())' "$TREE/node_modules/playwright-core" 2>/dev/null | tail -1)"
  fi
  if [ -z "$exe" ]; then
    missing="$missing
  - the Chromium path cannot be resolved (playwright-core is not installed in $TREE/node_modules)"
  elif [ ! -x "$exe" ]; then
    missing="$missing
  - Chromium is not installed: $exe"
  else
    dir="$(dirname "$(dirname "$exe")")"
    while [ "$(dirname "$dir")" != "$KIT/browsers" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do dir="$(dirname "$dir")"; done
    [ -f "$dir/INSTALLATION_COMPLETE" ] || missing="$missing
  - the Chromium install is incomplete: $dir/INSTALLATION_COMPLETE is missing"
  fi
  if [ -n "$missing" ]; then
    echo "E2E browser not ready:$missing" >&2
    echo "Fix: $FIX" >&2
    if [ "$(uname -s)" = Linux ] && [ -x "$TREE/node_modules/.bin/playwright" ]; then
      echo "System libraries (Linux), as reported by Playwright:" >&2
      "$TREE/node_modules/.bin/playwright" install-deps --dry-run chromium >&2 2>&1 || true
      echo "If libraries are missing, run once (the kit never runs sudo): sudo $TREE/node_modules/.bin/playwright install-deps chromium" >&2
    fi
    return 2
  fi
  echo "E2E browser ready: $exe"
}

install() {
  echo "1/2 npm ci --prefix $TREE"
  "$NPM" ci --prefix "$TREE" || { echo "ERROR: npm ci failed" >&2; return 1; }
  echo "2/2 playwright install --no-shell chromium (PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWSERS_PATH)"
  "$TREE/node_modules/.bin/playwright" install --no-shell chromium || { echo "ERROR: playwright install chromium failed" >&2; return 1; }
  check
}

session() {
  local url="" proj="" ident=default ho host origin state login now mtime out code detail
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) [ $# -ge 2 ] || { echo "ERROR: --as needs an identity." >&2; return 1; }; ident="$2"; shift 2;;
      *) if [ -z "$url" ]; then url="$1"; elif [ -z "$proj" ]; then proj="$1"; else sed -n 2,9p "$0" >&2; return 1; fi; shift;;
    esac
  done
  case "$url" in http://?*|https://?*) ;; *) sed -n 2,9p "$0" >&2; return 1;; esac
  # shellcheck source=/dev/null
  . "$KIT/bin/lib.sh"
  # shellcheck disable=SC2088
  login="~/.orca-roles/bin/browser-login.sh $url"
  [ -z "$proj" ] || login="$login $proj"
  [ "$ident" = default ] || login="$login --as $ident"
  [ -n "$proj" ] || proj="$(project_name .)"
  state="$(session_file "$proj" "$ident")" || return 1
  ho="$(url_host_origin "$url")" || { sed -n 2,9p "$0" >&2; return 1; }
  host="$(printf '%s\n' "$ho" | sed -n 1p)"; origin="$(printf '%s\n' "$ho" | sed -n 2p)"
  migrate_session "$proj"
  now="$(date +%s)"
  mtime="$(stat -c %Y "$state" 2>/dev/null || stat -f %m "$state" 2>/dev/null || echo 0)"
  if [ -f "$state" ]; then
    out="$(jq -r --arg host "$host" --arg origin "$origin" --argjson now "$now" --argjson mtime "$mtime" '
      def hostmatch($d): ($d // "") as $d | if ($d | startswith(".")) then ($host == $d[1:] or ($host | endswith($d))) else $host == $d end;
      def norm: ascii_downcase | sub("^(?<s>http://[^/]*):80$"; .s) | sub("^(?<s>https://[^/]*):443$"; .s);
      ((.cookies // []) | map(select(hostmatch(.domain)))) as $hc
      | ($hc | map(select((.expires // -1) > 0))) as $pers
      | ($pers | map(select(.expires > $now))) as $live
      | ((.origins // []) | map(select((.origin // "" | norm) == $origin and ((.localStorage // []) | length) > 0)) | length > 0) as $ls
      | if ((.cookies // []) | length) + ((.origins // []) | length) == 0 then "3|missing"
        elif ($hc | length) == 0 and ($ls | not) then "4|no-session-for-host"
        elif ($live | length) > 0 or $ls then
          "0|ok: session for \($origin) saved \($mtime | todate)"
          + (if ($live | length) > 0 then "; earliest cookie expiry \($live | map(.expires) | min | floor | todate)" else "; no persistent cookie, localStorage for the origin" end)
        elif ($pers | length) > 0 then "5|expired"
        else "6|unknown" end' "$state" 2>/dev/null)" || out="3|missing"
  else out="3|missing"; fi
  code="${out%%|*}"; detail="${out#*|}"
  case "$code" in
    0) echo "$detail";;
    3) echo "missing: no saved session for identity '$ident' of project '$proj' ($state)";;
    4) echo "no-session-for-host: $state has no cookies for $host nor localStorage for $origin";;
    5) echo "expired: every persistent cookie for $host in $state has expired and there is no localStorage for $origin";;
    6) echo "unknown: $state has only session cookies (no expiry) for $host and no localStorage for $origin; it cannot tell whether the session is still valid";;
  esac
  [ "$code" = 0 ] || echo "Login: $login"
  return "$code"
}

case "${1:-}" in
  check) check;;
  install) install;;
  session) shift; session "$@";;
  *) sed -n 2,9p "$0" >&2; exit 1;;
esac
