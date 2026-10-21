#!/usr/bin/env bash
# Creates the academic-research document structure (experimentation/ and article/) in a repository where it is missing.
# Usage: academic-scaffold.sh <repo top-level>
# Idempotent: it never overwrites or deletes anything and runs no git command that changes anything. It prints one line per folder or
# file it creates or changes, and nothing when there is nothing to do. A folder it creates gets an empty .gitkeep if git tracks its
# content (not data, models, logs, raw results or the literature PDFs); .gitignore gets the lines of the structure that it lacks.
# launch.sh runs it in academic-research mode.
set -uo pipefail
TOP="${1:-}"
[ -d "$TOP" ] || { echo "academic-scaffold.sh: usage: academic-scaffold.sh <repo top-level> (a directory)" >&2; exit 1; }
DIRS="experimentation/configs experimentation/data experimentation/models experimentation/src experimentation/scripts experimentation/specs experimentation/tests experimentation/results experimentation/results/raw experimentation/logs article/sections article/literature article/literature/pdfs article/tables article/images article/template"
UNTRACKED="experimentation/data experimentation/models experimentation/logs experimentation/results/raw article/literature/pdfs"
IGNORES='experimentation/data/*
!experimentation/data/README.md
experimentation/models/*
!experimentation/models/README.md
experimentation/logs/
experimentation/results/raw/
article/literature/pdfs/
article/build/
*.aux
*.bbl
*.blg
*.fdb_latexmk
*.fls
*.out
*.synctex.gz
*.toc
*.lof
*.lot
article/**/*.log'
for d in $DIRS; do
  [ -d "$TOP/$d" ] && continue
  mkdir -p "$TOP/$d" || { echo "academic-scaffold.sh: could not create $d" >&2; exit 1; }
  echo "Created $d"
  case " $UNTRACKED " in *" $d "*) continue;; esac
  : > "$TOP/$d/.gitkeep" && echo "Created $d/.gitkeep"
done
GI="$TOP/.gitignore"; HEADER="# orca-roles academic-research"; OLDHEADER="# orca-roles academic-writer"; CHANGED=0
[ -f "$GI" ] || { : > "$GI" || exit 1; echo "Created .gitignore"; }
while IFS= read -r line; do
  grep -qxF -- "$line" "$GI" && continue
  if [ "$CHANGED" = 0 ]; then
    [ -z "$(tail -c1 "$GI")" ] || echo >> "$GI"
    if ! grep -qxF -- "$HEADER" "$GI" && ! grep -qxF -- "$OLDHEADER" "$GI"; then
      [ -s "$GI" ] && [ -n "$(tail -n1 "$GI")" ] && echo >> "$GI"
      echo "$HEADER" >> "$GI"
    fi
    CHANGED=1
  fi
  echo "$line" >> "$GI"
done <<EOF2
$IGNORES
EOF2
[ "$CHANGED" = 0 ] || echo "Updated .gitignore"
exit 0
