#!/usr/bin/env bash
# Explains how to register launch.sh as each project's setup script. Orca's CLI has no command for
# setup scripts, so the installer cannot do it by itself: there are two ways.
set -euo pipefail
echo
echo "The kit still has to be registered in each project (once per project). Pick one way:"
echo "  a) In Orca: Settings → Repository → <project> → Setup script, paste:"
echo "       \$HOME/.orca-roles/bin/launch.sh"
echo "  b) In a terminal inside the project: roles-yaml"
echo "     (creates a local orca.yaml, ignored by git: nothing to commit)"
