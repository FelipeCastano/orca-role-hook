#!/usr/bin/env bash
# orca-roles installer.
#
# From GitHub (without cloning):
#   curl -fsSL https://raw.githubusercontent.com/FelipeCastano/orca-role-hook/main/install.sh | bash   (only if the repo is public)
# From a local clone:
#   ./install.sh
# All the configuration (enabled roles, models, agents, MCP, parameters) lives in ~/.orca-roles/config.json
# Version: ORCA_ROLES_REF=<branch|tag|sha> pins what the download installs (ORCA_ROLES_BRANCH still works; default: main).
#   Installed version and source: ~/.orca-roles/VERSION and ~/.orca-roles/.installed (also the first line of 'roles --status').
# Local edits: files of bin/, prompts/, plugin/ and mcp/ you changed or added since the last install are copied to
#   ~/.orca-roles/backup/<UTC timestamp>/ before being replaced, and listed in a WARNING. The install never stops or asks.
set -euo pipefail

REPO="${ORCA_ROLES_REPO:-FelipeCastano/orca-role-hook}"
REF="${ORCA_ROLES_REF:-${ORCA_ROLES_BRANCH:-main}}"   # a branch, tag or commit sha
KIT="$HOME/.orca-roles"
# The superpowers plugin the Planner loads: a pinned copy (this commit of this repository), outside the folders the install regenerates
SP_REPO="https://github.com/obra/superpowers.git"
SP_SHA="2ce8aa15d05bd57213e6f746f953aafb7ded7a8b"
SP_DIR="$KIT/plugins/superpowers"
SP_MARK="$SP_DIR/.orca-roles-pin"   # holds the sha of the installed copy

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n 2,13p "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0;;
    *) echo "Unknown option: $1 (roles are enabled in $KIT/config.json)" >&2; exit 1;;
  esac
done

# Requirements: jq is essential (the whole kit reads the configuration with it); the rest can be installed later.
command -v jq >/dev/null || { echo "ERROR: 'jq' is missing (macOS: brew install jq; Ubuntu: sudo apt install jq). Without it the kit can neither be installed nor run." >&2; exit 1; }
command -v orca >/dev/null || command -v "${ORCA_CLI_COMMAND:-orca}" >/dev/null || echo "Warning: the Orca CLI is not on the PATH. On Windows (WSL), run the installer from an Orca terminal (see README → Windows with WSL2)."
command -v claude >/dev/null || echo "Warning: 'claude' is not on the PATH (see README → Requirements)."
if command -v claude >/dev/null && ! claude --help 2>/dev/null | grep -A4 'permission-mode <mode>' | grep -q '"auto"'; then
  echo "Warning: your Claude Code ($(claude --version 2>/dev/null | head -1)) does not offer --permission-mode auto. Update it or change 'permissionMode' in config.json."
fi

# Source: the local clone if the script runs from it; otherwise (curl | bash), download the repo.
SRC=""; SOURCE="$REPO"; INST_REF="$REF"; INST_SHA=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -z "$SRC" ] || [ ! -d "$SRC/bin" ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  echo "Downloading $REPO ($REF)..."
  if ! curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$TMP" 2>/dev/null; then
    echo "Could not download $REPO. If the repo is private, clone it and run ./install.sh from the clone." >&2; exit 1
  fi
  SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
  case "$REF" in *[!0-9a-f]*) ;; *) [ "${#REF}" -ne 40 ] || INST_SHA="$REF";; esac   # a full sha names the commit without a network call
elif [ -n "${SRC:-}" ] && [ "$(git -C "$SRC" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then   # local clone: record what it has checked out
  SOURCE=local; INST_REF="$(git -C "$SRC" symbolic-ref --short -q HEAD || echo detached)"
  INST_SHA="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$INST_SHA" ] && [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then INST_SHA="$INST_SHA-dirty"; fi
else
  SOURCE=local; INST_REF=unknown
fi

# manifest_of <dir>: "<sha1>  <relative path>" of every file the install regenerates, plus the top-level README.md, config.default.json and VERSION, sorted
manifest_of() {
  local f
  ( cd "$1" && { find bin prompts plugin mcp grafana -type f 2>/dev/null || true; ls -d README.md config.default.json VERSION 2>/dev/null || true; } | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(shasum < "$f" | cut -d' ' -f1)" "$f"
    done )
}

# Copy of the kit (your config.json and your roles in ~/.orca-roles/roles/ are kept across updates)
mkdir -p "$KIT"
# Files you changed or added in the regenerated folders since the last install are saved aside first (no manifest: nothing to compare)
if [ -f "$KIT/.manifest" ]; then
  NOW="$(mktemp)"; manifest_of "$KIT" > "$NOW"
  # changed: another hash than in the old manifest; or absent from it and in a folder that was always listed (the top-level files are new in the manifest)
  CHANGED="$(awk 'NR == FNR { old[substr($0, 43)] = $1; next }
    { p = substr($0, 43) }
    p in old { if (old[p] != $1) print p; next }
    p ~ /^(bin|prompts|plugin|mcp|grafana)\// { print p }' "$KIT/.manifest" "$NOW" || true)"
  rm -f "$NOW"
  if [ -n "$CHANGED" ]; then
    BK="$KIT/backup/$(date -u +%Y%m%dT%H%M%SZ)"
    while IFS= read -r f; do
      mkdir -p "$BK/$(dirname "$f")"; cp -p "$KIT/$f" "$BK/$f"
    done <<<"$CHANGED"
    echo "WARNING: these files in $KIT were modified or added since the last install and are replaced now:"
    while IFS= read -r f; do echo "  $f"; done <<<"$CHANGED"
    echo "Your copies are in $BK (restore what you need from there)."
  fi
fi
rm -rf "${KIT:?}/bin" "${KIT:?}/prompts" "${KIT:?}/plugin" "${KIT:?}/mcp" "${KIT:?}/grafana"   # regenerated; config.json and roles/ are not touched
cp -R "$SRC/bin" "$SRC/prompts" "$SRC/plugin" "$SRC/README.md" "$SRC/config.default.json" "$KIT/"
find "$KIT/bin" -name __pycache__ -type d -prune -exec rm -rf {} +
if [ -d "$SRC/grafana" ]; then cp -R "$SRC/grafana" "$KIT/"; fi
chmod +x "$KIT/bin/"*.sh
if [ -f "$SRC/VERSION" ]; then cp "$SRC/VERSION" "$KIT/VERSION"; else rm -f "$KIT/VERSION"; fi   # refs older than the VERSION file have none
echo "$SOURCE@$INST_REF${INST_SHA:+ $INST_SHA}" > "$KIT/.installed"
manifest_of "$KIT" > "$KIT/.manifest"   # written right after the copy, so a later failed step cannot leave a stale one
mkdir -p "$KIT/pw"   # the pinned browser stack: node_modules and browsers/ are kept across updates
cp "$SRC/pw/package.json" "$SRC/pw/package-lock.json" "$SRC/pw/e2e.config.js" "$KIT/pw/"
rm -f "$KIT/config.env"   # old format
# Installs the pinned superpowers copy unless it is already there. Never aborts the install: a failure only warns.
fetch_superpowers() {
  local short="${SP_SHA:0:7}" tmp old prev reason=""
  if [ "${ORCA_ROLES_SUPERPOWERS_FETCH:-}" = skip ]; then echo "Superpowers: fetch skipped (ORCA_ROLES_SUPERPOWERS_FETCH=skip)."; return 0; fi
  if [ -f "$SP_MARK" ] && [ "$(cat "$SP_MARK" 2>/dev/null)" = "$SP_SHA" ]; then echo "Superpowers $short already installed."; return 0; fi
  if ! command -v git >/dev/null 2>&1; then echo "Warning: git is missing: superpowers for the Planner was not installed (the Planner works without it)."; return 0; fi
  if [ -d "$SP_DIR" ]; then prev="the previous copy is kept"; else prev="the Planner works without it"; fi
  # the temporary copy lives next to its destination, so the final mv is a rename on the same device
  mkdir -p "$KIT/plugins" 2>/dev/null && tmp="$(mktemp -d "$KIT/plugins/.superpowers.XXXXXX" 2>/dev/null)" \
    || { echo "Warning: could not install superpowers $short for the Planner (no temporary folder); $prev."; return 0; }
  (cd "$tmp" && git init -q && GIT_TERMINAL_PROMPT=0 git fetch -q --depth 1 "$SP_REPO" "$SP_SHA" && git checkout -q FETCH_HEAD) >/dev/null 2>&1 || reason="fetch or checkout failed"
  if [ -z "$reason" ] && [ "$(git -C "$tmp" rev-parse HEAD 2>/dev/null)" != "$SP_SHA" ]; then reason="the fetched commit is not the pinned one"; fi
  if [ -z "$reason" ]; then
    rm -rf "$tmp/.git"; chmod 755 "$tmp"
    printf '%s\n' "$SP_SHA" > "$tmp/.orca-roles-pin" || reason="could not write the marker"
  fi
  if [ -z "$reason" ]; then
    old="$SP_DIR.old.$$"
    if [ -d "$SP_DIR" ]; then mv "$SP_DIR" "$old" || reason="could not move the previous copy aside"; fi
    if [ -z "$reason" ]; then
      if mv "$tmp" "$SP_DIR"; then rm -rf "$old"
      else reason="could not move the new copy into place"; rm -rf "$SP_DIR"; if [ -d "$old" ]; then mv "$old" "$SP_DIR"; fi; fi
    fi
  fi
  rm -rf "$tmp"
  if [ -n "$reason" ]; then echo "Warning: could not install superpowers $short for the Planner ($reason); $prev."
  else echo "Installed superpowers $short for the Planner."; fi
  return 0
}
fetch_superpowers || true
. "$KIT/bin/lib.sh"
CONF="$KIT/config.json"
if [ ! -f "$CONF" ]; then
  cp "$KIT/config.default.json" "$CONF"; echo "Created your configuration: $CONF"
else
  # Adds new roles or keys from the installed version without overwriting what you already have (or the order of your roles)
  TMPC="$(mktemp)"
  upgrade_config "$KIT/config.default.json" "$CONF" "$KIT" > "$TMPC"
  mv "$TMPC" "$CONF"
fi
jq empty "$CONF" || { echo "ERROR: $CONF is not valid JSON" >&2; exit 1; }

# Aliases 'roles', 'new-role', 'roles-yaml' and 'team-status' (once)
# zsh → ~/.zshrc; bash → ~/.bashrc (on macOS, ~/.bash_profile, which is what Terminal reads); other shells → ~/.profile
case "$(basename "${SHELL:-}")" in
  zsh) RC="$HOME/.zshrc";;
  bash) if [ "$(uname -s)" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi;;
  *) RC="$HOME/.profile";;
esac
grep -q 'alias roles=' "$RC" 2>/dev/null || echo 'alias roles="$HOME/.orca-roles/bin/launch.sh"' >> "$RC"
grep -q 'alias new-role=' "$RC" 2>/dev/null || echo 'alias new-role="$HOME/.orca-roles/bin/new-role.sh"' >> "$RC"
grep -q 'alias roles-yaml=' "$RC" 2>/dev/null || echo 'alias roles-yaml="$HOME/.orca-roles/bin/orca-yaml.sh"' >> "$RC"
grep -q 'alias team-status=' "$RC" 2>/dev/null || echo 'alias team-status="$HOME/.orca-roles/bin/team-status.sh"' >> "$RC"
# In Orca's WSL terminals the CLI is called $ORCA_CLI_COMMAND (e.g. orca-ide): 'orca' points to it there, and does nothing elsewhere
grep -q 'orca-roles: orca alias' "$RC" 2>/dev/null || echo '[ -n "${ORCA_CLI_COMMAND:-}" ] && ! command -v orca >/dev/null 2>&1 && alias orca="$ORCA_CLI_COMMAND"   # orca-roles: orca alias' >> "$RC"

# On WSL, tabs Orca resumes itself (a bare 'claude --resume' in a fresh shell) do not get the orca shim that agent.sh puts on the PATH: link it into
# ~/.local/bin when that is on the PATH, else add a marked line to ~/.profile. Nothing happens off WSL or when orca already resolves (no shim).
if is_wsl && [ -e "$KIT/shim/orca" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*)
      OLNK="$HOME/.local/bin/orca"
      if [ -e "$OLNK" ] || [ -L "$OLNK" ]; then
        [ -L "$OLNK" ] && [ "$(readlink "$OLNK")" = "$KIT/shim/orca" ] || echo "Note: ~/.local/bin/orca exists and is not the kit's shim; left as is."
      else
        mkdir -p "$HOME/.local/bin" && ln -sfn "$KIT/shim/orca" "$OLNK"
      fi;;
    *)
      OMARK="# orca-roles: orca shim"
      if [ "$KIT" = "$HOME/.orca-roles" ]; then OP='$HOME/.orca-roles'; else OP="$(printf '%s' "$KIT" | sed 's/[\\"$`]/\\&/g')"; fi
      OLINE="[ -x \"$OP/shim/orca\" ] && case \":\$PATH:\" in *\":$OP/shim:\"*) ;; *) PATH=\"$OP/shim:\$PATH\";; esac   $OMARK"
      OPROF="$HOME/.profile"
      if grep -qxF -- "$OLINE" "$OPROF" 2>/dev/null; then :
      elif grep -qF -- "$OMARK" "$OPROF" 2>/dev/null; then
        OTMP="$(mktemp)" && OL="$OLINE" OM="$OMARK" awk 'index($0, ENVIRON["OM"]) { print ENVIRON["OL"]; next } { print }' "$OPROF" > "$OTMP" && cat "$OTMP" > "$OPROF"; rm -f "$OTMP"
      else
        printf '%s\n' "$OLINE" >> "$OPROF"
      fi;;
  esac
fi

# Claude Code SessionStart hook: re-binds a reopened tab's Orca Runs (bin/session-hook.sh); settings.sessionHook false removes it
if [ "$(setting "$CONF" sessionHook true)" = false ]; then
  remove_session_hook
else
  ensure_session_hook_or_warn --backup
  # shellcheck disable=SC2154
  [ "${SESSION_HOOK_CHANGED:-0}" != 1 ] || echo "Claude Code SessionStart hook: added to ~/.claude/settings.json (re-binds Orca Runs when a tab reopens)."
fi

# Usage metrics: maps the worktrees the kit knows (the folders it recorded in trusted.list) that were not launched since this update; never fatal
if metrics_enabled "$CONF" && [ -f "$(trusted_list)" ]; then
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    ph="$(cd "$wt" && pwd -P)" || continue
    grep -qF "\"physical\":$(printf '%s' "$ph" | jq -Rs .)" "$(metrics_dir)/worktrees.jsonl" 2>/dev/null && continue
    wcfg=""; wgd="$(cd "$wt" && git rev-parse --absolute-git-dir 2>/dev/null)" && wcfg="$wgd/orca-roles.config.json"; [ -f "$wcfg" ] || wcfg="$CONF"
    metrics_worktree "$wt" "$(project_name "$wt" 2>/dev/null || basename "$wt")" "$(metrics_task "$wcfg" "$wt")"
  done < "$(trusted_list)"
fi

# Usage metrics scheduler: a pass of bin/usage-metrics.sh --once every settings.metrics.intervalSeconds (launchd on macOS; cron, every minute, on
# Linux/WSL). Only the user's own scheduler is touched, only here. ORCA_ROLES_SCHEDULER=fake (or fake-nocron: no crontab) logs the commands to
# $ORCA_ROLES_SCHEDULER_LOG instead of running launchctl/crontab (the test suite always sets it); ORCA_ROLES_SCHEDULER_OS then replaces uname -s.
MLABEL=com.orca-roles.usage-metrics; MMARK="# orca-roles usage-metrics"
sched_fake() { case "${ORCA_ROLES_SCHEDULER:-}" in fake|fake-nocron) return 0;; *) return 1;; esac; }
sched_run() { if sched_fake; then printf '%s\n' "$*" >> "${ORCA_ROLES_SCHEDULER_LOG:-/dev/null}"; else "$@"; fi; }
sched_crontab_list() { if sched_fake; then cat "${ORCA_ROLES_SCHEDULER_LOG:-/dev/null}.crontab" 2>/dev/null || true; else crontab -l 2>/dev/null || true; fi; }
sched_crontab_set() { if sched_fake; then cat > "${ORCA_ROLES_SCHEDULER_LOG:-/dev/null}.crontab"; printf 'crontab -\n' >> "${ORCA_ROLES_SCHEDULER_LOG:-/dev/null}"; else crontab -; fi; }
sched_have_crontab() { if sched_fake; then [ "${ORCA_ROLES_SCHEDULER:-}" = fake ]; else command -v crontab >/dev/null 2>&1; fi; }
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
schedule_metrics() {
  local os plist uid py interval line cur
  os="$(uname -s)"; if sched_fake && [ -n "${ORCA_ROLES_SCHEDULER_OS:-}" ]; then os="$ORCA_ROLES_SCHEDULER_OS"; fi
  plist="$HOME/Library/LaunchAgents/$MLABEL.plist"; uid="$(id -u)"
  if ! metrics_enabled "$CONF"; then
    if [ "$os" = Darwin ]; then
      if [ -f "$plist" ]; then sched_run launchctl bootout "gui/$uid/$MLABEL" >/dev/null 2>&1 || true; rm -f "$plist"; fi
    elif sched_have_crontab; then
      cur="$(sched_crontab_list)"
      if printf '%s\n' "$cur" | grep -qF "$MMARK"; then printf '%s\n' "$cur" | grep -vF "$MMARK" | sched_crontab_set; fi
    fi
    echo "Usage metrics: off (settings.metrics.enabled is false); nothing is scheduled."
    return 0
  fi
  if ! py="$(command -v python3 2>/dev/null)" || [ -z "$py" ] || ! "$py" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
    echo "Usage metrics: no python3 >= 3.9 found; metrics are not scheduled."; return 0
  fi
  case "$py" in /*) ;; *) py="$(cd "$(dirname "$py")" && pwd)/$(basename "$py")";; esac
  interval="$(jq -r '(.settings.metrics? | objects | .intervalSeconds?) // 60' "$CONF" 2>/dev/null)"
  case "$interval" in ''|*[!0-9]*) interval=60;; esac
  if [ "$interval" -lt 15 ] || [ "$interval" -gt 3600 ]; then interval=60; fi
  if [ "$os" = Darwin ]; then
    mkdir -p "$(dirname "$plist")" "$KIT/metrics"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$MLABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_esc "$KIT/bin/usage-metrics.sh")</string>
    <string>--once</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ORCA_ROLES_PYTHON</key><string>$(xml_esc "$py")</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$(xml_esc "$HOME")</string>
  </dict>
  <key>StartInterval</key><integer>$interval</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml_esc "$KIT/metrics/usage-metrics.launchd.log")</string>
  <key>StandardErrorPath</key><string>$(xml_esc "$KIT/metrics/usage-metrics.launchd.log")</string>
</dict>
</plist>
PLIST
    sched_run launchctl bootout "gui/$uid/$MLABEL" >/dev/null 2>&1 || true
    if sched_run launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1; then echo "Usage metrics: recorded every $interval s (launchd)."
    else echo "Warning: launchctl could not load $plist; run: launchctl bootstrap gui/$uid $plist"; fi
  elif sched_have_crontab; then
    line="* * * * * ORCA_ROLES_PYTHON=$py /bin/bash $KIT/bin/usage-metrics.sh --once >/dev/null 2>&1 $MMARK"
    cur="$(sched_crontab_list)"
    { printf '%s\n' "$cur" | grep -vF "$MMARK" | sed '/^$/d' || true; printf '%s\n' "$line"; } | sched_crontab_set
    echo "Usage metrics: recorded every minute (cron)."
  else
    echo "Usage metrics: no crontab found; run $KIT/bin/usage-metrics.sh --once yourself or schedule it."
  fi
  return 0
}
schedule_metrics || echo "Warning: could not set up the usage metrics scheduler."

echo
echo "Installed in $KIT"
echo "Configuration: $CONF"
echo "Available: $(jq -r '.roles | keys_unsorted | join(" ")' "$CONF")"
if m="$(mode_of "$CONF")"; then
  label="$m"; [ "$m" != academic-research ] || label="$m, phase $(phase_of "$CONF")"
  echo "Enabled ($label): $(enabled_roles "$CONF" | tr '\n' ' ')"
else
  echo "Enabled: unknown (invalid settings.mode)"
fi
echo "To enable or disable roles, edit \"enabled\" in $CONF."
"$KIT/bin/apply-hooks.sh"
echo "Open a new terminal (or 'source $RC') to use the 'roles', 'new-role', 'roles-yaml' and 'team-status' commands."
