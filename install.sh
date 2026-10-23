#!/usr/bin/env bash
# orca-roles installer.
#
# From GitHub (without cloning):
#   curl -fsSL https://raw.githubusercontent.com/FelipeCastano/orca-role-hook/main/install.sh | bash   (only if the repo is public)
# From a local clone:
#   ./install.sh
# All the configuration (enabled roles, models, agents, MCP, parameters) lives in ~/.orca-roles/config.json
set -euo pipefail

REPO="${ORCA_ROLES_REPO:-FelipeCastano/orca-role-hook}"
BRANCH="${ORCA_ROLES_BRANCH:-main}"
KIT="$HOME/.orca-roles"
# The superpowers plugin the Planner loads: a pinned copy (this commit of this repository), outside the folders the install regenerates
SP_REPO="https://github.com/obra/superpowers.git"
SP_SHA="2ce8aa15d05bd57213e6f746f953aafb7ded7a8b"
SP_DIR="$KIT/plugins/superpowers"
SP_MARK="$SP_DIR/.orca-roles-pin"   # holds the sha of the installed copy

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n 2,8p "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0;;
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
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -z "$SRC" ] || [ ! -d "$SRC/bin" ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  echo "Downloading $REPO ($BRANCH)..."
  if ! curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$TMP" 2>/dev/null; then
    echo "Could not download $REPO. If the repo is private, clone it and run ./install.sh from the clone." >&2; exit 1
  fi
  SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
fi

# Copy of the kit (your config.json and your roles in ~/.orca-roles/roles/ are kept across updates)
mkdir -p "$KIT"
rm -rf "${KIT:?}/bin" "${KIT:?}/prompts" "${KIT:?}/plugin" "${KIT:?}/mcp"   # regenerated; config.json and roles/ are not touched
cp -R "$SRC/bin" "$SRC/prompts" "$SRC/plugin" "$SRC/README.md" "$SRC/config.default.json" "$KIT/"
ln -s academic-research "$KIT/prompts/academic-writer"   # old path of the renamed mode, regenerated with prompts/
chmod +x "$KIT/bin/"*.sh
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
  RENAMED=0; ! config_has_old_mode "$CONF" || RENAMED=1
  upgrade_config "$KIT/config.default.json" "$CONF" "$KIT" > "$TMPC"
  mv "$TMPC" "$CONF"
  [ "$RENAMED" = 0 ] || echo "Renamed mode academic-writer to academic-research in your configuration ($CONF)."
fi
jq empty "$CONF" || { echo "ERROR: $CONF is not valid JSON" >&2; exit 1; }

# Your roles of the renamed mode: roles/academic-writer/ moves to roles/academic-research/, and the old path becomes a link to it
OLDR="$KIT/roles/academic-writer"; NEWR="$KIT/roles/academic-research"
if [ -L "$OLDR" ]; then
  [ "$(readlink "$OLDR")" = academic-research ] || { rm "$OLDR"; ln -s academic-research "$OLDR"; }
elif [ -d "$OLDR" ]; then
  mkdir -p "$NEWR"; MOVED=0; KEPT=""
  while IFS= read -r n; do
    if [ -e "$NEWR/$n" ] || [ -L "$NEWR/$n" ]; then KEPT="$KEPT$n"$'\n'; else mv "$OLDR/$n" "$NEWR/$n"; MOVED=1; fi
  done < <(find "$OLDR" -mindepth 1 -maxdepth 1 -exec basename {} \;)
  if [ -z "$KEPT" ]; then rmdir "$OLDR"; ln -s academic-research "$OLDR"; fi
  [ "$MOVED" = 0 ] || echo "Moved your academic-writer roles to $NEWR."
  while IFS= read -r n; do
    [ -z "$n" ] || echo "WARNING: $OLDR/$n was not moved: $NEWR/$n already exists. Any prompt path in your configuration that named the old file now names the new one. Merge them by hand, then run install.sh again."
  done <<<"$KEPT"
fi

# Aliases 'roles', 'new-role' and 'roles-yaml' (once)
# zsh → ~/.zshrc; bash → ~/.bashrc (on macOS, ~/.bash_profile, which is what Terminal reads); other shells → ~/.profile
case "$(basename "${SHELL:-}")" in
  zsh) RC="$HOME/.zshrc";;
  bash) if [ "$(uname -s)" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi;;
  *) RC="$HOME/.profile";;
esac
grep -q 'alias roles=' "$RC" 2>/dev/null || echo 'alias roles="$HOME/.orca-roles/bin/launch.sh"' >> "$RC"
grep -q 'alias new-role=' "$RC" 2>/dev/null || echo 'alias new-role="$HOME/.orca-roles/bin/new-role.sh"' >> "$RC"
grep -q 'alias roles-yaml=' "$RC" 2>/dev/null || echo 'alias roles-yaml="$HOME/.orca-roles/bin/orca-yaml.sh"' >> "$RC"
# In Orca's WSL terminals the CLI is called $ORCA_CLI_COMMAND (e.g. orca-ide): 'orca' points to it there, and does nothing elsewhere
grep -q 'orca-roles: orca alias' "$RC" 2>/dev/null || echo '[ -n "${ORCA_CLI_COMMAND:-}" ] && ! command -v orca >/dev/null 2>&1 && alias orca="$ORCA_CLI_COMMAND"   # orca-roles: orca alias' >> "$RC"

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
echo "Open a new terminal (or 'source $RC') to use the 'roles', 'new-role' and 'roles-yaml' commands."
