#!/usr/bin/env bash
# Writes the OpenCode configuration of a role.  Usage (from the role's worktree or pair tree): opencode-prepare.sh <role>
# agent.sh runs it before `opencode mini --standalone --agent orca-<role>` and passes the file as OPENCODE_CONFIG. The file is
# <team git dir>/orca-roles-opencode-<role>.json (oc_config_file), rewritten on every start (temp file + mv); its path is printed on stdout.
#   agents.orca-<role>: description, mode, model, steps (roles.<r>.opencode.steps, else settings.flow.maxStepsPerWorker, else none),
#     system (the role anchor, the role's common rules, the role's prompt) and permissions: allow everything first (a call that matches no
#     rule would wait for an answer that nobody gives in the tab), then roles.<r>.opencode.permissions as written, then the kit's denies
#     (question, subagent for the reviewers (Plan-Reviewer, Code-Reviewer, Verifier), git push, editing the kit's own files)
#   mcp.servers: the role's MCP servers (the file in ORCA_ROLES_MCP, from agent.sh) in OpenCode's format; none: no "mcp" key.
# Nothing is written in the worktree. An untracked <toplevel>/.opencode/agents/orca-<role>.md left by an older kit is deleted: OpenCode
# ranks the project's agents above OPENCODE_CONFIG, so it would replace the kit's agent; nothing is removed when <toplevel>/.opencode or
# <toplevel>/.opencode/agents is a symbolic link (an older kit's pair tree links them to the worktree's). A system prompt containing {env: or
# {file: gets a warning: OpenCode replaces those with a variable or a file's content when it loads the file.
set -euo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
ROLE="${1:-}"; [ -n "$ROLE" ] || { sed -n 2,2p "$0" >&2; exit 1; }
CFG="${ORCA_ROLES_CONFIG:-}"
W="$(mktemp -d "${TMPDIR:-/tmp}/orca-opencode.XXXXXX")"; TMPF=""; trap 'rm -rf "$W"; [ -z "$TMPF" ] || rm -f "$TMPF"' EXIT
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then CFG="$W/config.json"; merged_config . > "$CFG"; fi

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "opencode-prepare.sh: not inside a git repository; OpenCode roles need one" >&2; exit 1; }
KITP="$(cd "$KIT" && pwd -P)"
PROMPT="$(prompt_of "$CFG" "$ROLE")"
[ -f "$PROMPT" ] || { echo "opencode-prepare.sh: the prompt of $ROLE does not exist ($PROMPT)" >&2; exit 1; }
COMMON="$(common_of "$CFG" "$ROLE")"
[ -f "$COMMON" ] || { echo "opencode-prepare.sh: the common file of $ROLE does not exist ($COMMON)" >&2; exit 1; }
MODEL="$(role_model "$CFG" "$ROLE")"

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

OUT="$(oc_config_file "$ROLE")" || { echo "opencode-prepare.sh: could not find the git dir for $ROLE" >&2; exit 1; }
{ role_anchor "$CFG" "$ROLE"; printf '\n\n'; printf '%s\n\n' "$(cat "$COMMON")"; cat "$PROMPT"; } > "$W/system"   # one blank line between the parts
if grep -qE '\{(env|file):' "$W/system"; then
  echo "opencode-prepare.sh: warning: the system prompt of $ROLE contains {env: or {file:, which OpenCode replaces with an environment variable or a file's content when it loads the role's configuration." >&2
fi
SERVERS='{}'
if [ -n "${ORCA_ROLES_MCP:-}" ] && [ -f "$ORCA_ROLES_MCP" ]; then
  SERVERS="$(opencode_mcp_servers "$ORCA_ROLES_MCP")" || { echo "opencode-prepare.sh: could not read the MCP servers of $ROLE ($ORCA_ROLES_MCP)" >&2; exit 1; }
fi
TMPF="$OUT.tmp.$$"
# The role's own permissions come before the kit's denies: OpenCode applies the last matching rule, so the kit's guards cannot be
# undone by the role's list (as for Claude roles).
jq -n --arg title "$(title_of "$CFG" "$ROLE")" --arg model "$MODEL" --arg steps "$STEPS" --arg kit "$KITP" --arg role "$ROLE" --arg paths "$(kit_protected_paths)" \
  --slurpfile extra "$EXTRA_OK" --arg id "orca-$ROLE" --rawfile system "$W/system" --argjson servers "$SERVERS" '
  {agents: {($id): ({description: "orca-roles \($title) role", mode: "primary"}
    + (if $model != "" then {model: $model} else {} end)
    + (if $steps != "" then {steps: ($steps | tonumber)} else {} end)
    + {system: $system, permissions:
      ([{action: "*", resource: "*", effect: "allow"}] + $extra
       + [{action: "question", resource: "*", effect: "deny"}]
       + (if ($role == "plan-reviewer" or $role == "code-reviewer" or $role == "verifier") then [{action: "subagent", resource: "*", effect: "deny"}] else [] end)
       + [{action: "shell", resource: "git push*", effect: "deny"}]
       + ($paths | split("\n") | map(select(. != "")) | map({action: "edit", resource: "\($kit)/\(.)", effect: "deny"})))})}}
  + (if ($servers | length) > 0 then {mcp: {servers: $servers}} else {} end)' > "$TMPF" || { echo "opencode-prepare.sh: could not write $OUT" >&2; exit 1; }
mv "$TMPF" "$OUT"; TMPF=""

# An agent file left by an older kit would override the kit's agent (the project's agents rank above OPENCODE_CONFIG). Tracked files and
# anything behind a symbolic link stay.
STALE="$TOP/.opencode/agents/orca-$ROLE.md"
if [ ! -L "$TOP/.opencode" ] && [ ! -L "$TOP/.opencode/agents" ]; then
  if { [ -f "$STALE" ] || [ -L "$STALE" ]; } && ! git -C "$TOP" ls-files --error-unmatch -- ".opencode/agents/orca-$ROLE.md" >/dev/null 2>&1; then
    rm -f "$STALE"
    rmdir "$TOP/.opencode/agents" 2>/dev/null && rmdir "$TOP/.opencode" 2>/dev/null || true
  fi
fi
printf '%s\n' "$OUT"
