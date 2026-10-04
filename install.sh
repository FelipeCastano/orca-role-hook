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
chmod +x "$KIT/bin/"*.sh
rm -f "$KIT/config.env"   # old format
. "$KIT/bin/lib.sh"
CONF="$KIT/config.json"
if [ ! -f "$CONF" ]; then
  cp "$KIT/config.default.json" "$CONF"; echo "Created your configuration: $CONF"
else
  # Adds new roles or keys from the installed version without overwriting what you already have (or the order of your roles)
  TMPC="$(mktemp)"
  upgrade_config "$KIT/config.default.json" "$CONF" > "$TMPC"
  mv "$TMPC" "$CONF"
fi
jq empty "$CONF" || { echo "ERROR: $CONF is not valid JSON" >&2; exit 1; }

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
echo "Enabled:   $(enabled_roles "$CONF" | tr '\n' ' ')"
echo "To enable or disable roles, edit \"enabled\" in $CONF."
"$KIT/bin/apply-hooks.sh"
echo "Open a new terminal (or 'source $RC') to use the 'roles', 'new-role' and 'roles-yaml' commands."
