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

# manifest_of <dir>: "<sha1>  <relative path>" of every file the install regenerates, sorted
manifest_of() {
  local f
  ( cd "$1" && { find bin prompts plugin mcp -type f 2>/dev/null || true; } | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(shasum < "$f" | cut -d' ' -f1)" "$f"
    done )
}

# Copy of the kit (your config.json and your roles in ~/.orca-roles/roles/ are kept across updates)
mkdir -p "$KIT"
# Files you changed or added in the regenerated folders since the last install are saved aside first (no manifest: nothing to compare)
if [ -f "$KIT/.manifest" ]; then
  NOW="$(mktemp)"; manifest_of "$KIT" > "$NOW"
  CHANGED="$(grep -vxFf "$KIT/.manifest" "$NOW" | sed 's/^[0-9a-f]*  //' || true)"
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
rm -rf "${KIT:?}/bin" "${KIT:?}/prompts" "${KIT:?}/plugin" "${KIT:?}/mcp"   # regenerated; config.json and roles/ are not touched
cp -R "$SRC/bin" "$SRC/prompts" "$SRC/plugin" "$SRC/README.md" "$SRC/config.default.json" "$KIT/"
ln -s academic-research "$KIT/prompts/academic-writer"   # old path of the renamed mode, regenerated with prompts/
chmod +x "$KIT/bin/"*.sh
if [ -f "$SRC/VERSION" ]; then cp "$SRC/VERSION" "$KIT/VERSION"; else rm -f "$KIT/VERSION"; fi   # refs older than the VERSION file have none
echo "$SOURCE@$INST_REF${INST_SHA:+ $INST_SHA}" > "$KIT/.installed"
manifest_of "$KIT" > "$KIT/.manifest"   # written right after the copy, so a later failed step cannot leave a stale one
mkdir -p "$KIT/pw"   # the pinned browser stack: node_modules and browsers/ are kept across updates
cp "$SRC/pw/package.json" "$SRC/pw/package-lock.json" "$SRC/pw/e2e.config.js" "$KIT/pw/"
rm -f "$KIT/config.env"   # old format
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
