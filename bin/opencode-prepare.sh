#!/usr/bin/env bash
# Writes the OpenCode agent file of a role.  Usage (from the role's worktree): opencode-prepare.sh <role>
# agent.sh runs it before `opencode mini --agent orca-<role>`. The file is <worktree>/.opencode/agents/orca-<role>.md, rewritten on every
# start (temp file + mv), and its pattern goes once into the repo's info/exclude, never into a tracked .gitignore.
#   frontmatter: description, mode, model, steps (roles.<r>.opencode.steps, else settings.flow.maxStepsPerWorker, else none) and
#     permissions: allow everything first (a call that matches no rule would wait for an answer that nobody gives in the tab),
#     then the denies (question, git push, editing the kit's own files), then roles.<r>.opencode.permissions as written
#   body (the agent's system prompt): the role anchor, the role's common rules, the role's prompt
set -euo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
ROLE="${1:-}"; [ -n "$ROLE" ] || { sed -n 2,2p "$0" >&2; exit 1; }
CFG="${ORCA_ROLES_CONFIG:-}"
W="$(mktemp -d "${TMPDIR:-/tmp}/orca-opencode.XXXXXX")"; TMPF=""; trap 'rm -rf "$W"; [ -z "$TMPF" ] || rm -f "$TMPF"' EXIT
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then CFG="$W/config.json"; merged_config . > "$CFG"; fi

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "opencode-prepare.sh: not inside a git repository; OpenCode roles need one" >&2; exit 1; }
COMMON_DIR="$(git rev-parse --git-common-dir)"; COMMON_DIR="$(cd "$COMMON_DIR" && pwd -P)"
KITP="$(cd "$KIT" && pwd -P)"
PROMPT="$(prompt_of "$CFG" "$ROLE")"
[ -f "$PROMPT" ] || { echo "opencode-prepare.sh: the prompt of $ROLE does not exist ($PROMPT)" >&2; exit 1; }
COMMON="$(common_of "$CFG" "$ROLE")"
[ -f "$COMMON" ] || { echo "opencode-prepare.sh: the common file of $ROLE does not exist ($COMMON)" >&2; exit 1; }
MODEL="$(rstr "$CFG" "$ROLE" model)"

# steps: the role's own value, else the flow default; a role value that is not a positive integer is dropped with a warning
STEPS="$(jq -r --arg r "$ROLE" '(.roles[$r].opencode? | objects | .steps?) // empty | if type == "number" and . == floor and . > 0 then "ok \(.)" else "bad \(tojson)" end' "$CFG" 2>/dev/null)"
case "$STEPS" in
  "ok "*) STEPS="${STEPS#ok }";;
  "bad "*) echo "opencode-prepare.sh: roles.$ROLE.opencode.steps must be a positive integer (got ${STEPS#bad }); leaving it out" >&2; STEPS="";;
  *) STEPS="$(flow_max_steps "$CFG")";;
esac

# The role's own permissions: each item needs string action and resource and effect allow|ask|deny; others are skipped with a warning
EXTRA="$W/extra"; EXTRA_OK="$W/extra-ok"; : > "$EXTRA_OK"
jq -c --arg r "$ROLE" '(.roles[$r].opencode? | objects | .permissions?) // empty | if type == "array" then .[] else "bad-list" end' "$CFG" 2>/dev/null > "$EXTRA" || true
while IFS= read -r item; do
  [ -n "$item" ] || continue
  if [ "$item" = '"bad-list"' ]; then echo "opencode-prepare.sh: roles.$ROLE.opencode.permissions must be a list; ignoring it" >&2; continue; fi
  if printf '%s' "$item" | jq -e 'type == "object" and (.action | type) == "string" and (.resource | type) == "string" and (.effect | IN("allow","ask","deny"))' >/dev/null 2>&1; then
    printf '%s\n' "$item" >> "$EXTRA_OK"
  else
    echo "opencode-prepare.sh: skipping an invalid item of roles.$ROLE.opencode.permissions ($item)" >&2
  fi
done < "$EXTRA"

DIR="$TOP/.opencode/agents"; mkdir -p "$DIR"
OUT="$DIR/orca-$ROLE.md"; TMPF="$(mktemp "$DIR/.orca-$ROLE.XXXXXX")"
# The role's own permissions come before the kit's denies: OpenCode applies the last matching rule, so the kit's guards cannot be
# undone by the role's list (as for Claude roles).
{
  echo "---"
  jq -nr --arg title "$(title_of "$CFG" "$ROLE")" --arg model "$MODEL" --arg steps "$STEPS" --arg kit "$KITP" --slurpfile extra "$EXTRA_OK" '
    "description: \("orca-roles \($title) role" | tojson)", "mode: \("primary" | tojson)",
    (if $model != "" then "model: \($model | tojson)" else empty end),
    (if $steps != "" then "steps: \($steps)" else empty end),
    "permissions:",
    (([{action: "*", resource: "*", effect: "allow"}] + $extra
     + [{action: "question", resource: "*", effect: "deny"},
      {action: "shell", resource: "git push*", effect: "deny"}]
     + ([("prompts/**", "roles/**", "bin/**", "plugin/**", "config.json", "config.default.json")] | map({action: "edit", resource: "\($kit)/\(.)", effect: "deny"})))[] | "  - \(tojson)")'
  echo "---"
  role_anchor "$CFG" "$ROLE"; printf '\n\n'
  printf '%s\n\n' "$(cat "$COMMON")"   # exactly one blank line between the parts
  cat "$PROMPT"
} > "$TMPF"
mv "$TMPF" "$OUT"

# Keep the generated files out of git without touching a tracked .gitignore
mkdir -p "$COMMON_DIR/info"
PAT="/.opencode/agents/orca-*.md"
grep -qxF -- "$PAT" "$COMMON_DIR/info/exclude" 2>/dev/null || printf '%s\n' "$PAT" >> "$COMMON_DIR/info/exclude"
