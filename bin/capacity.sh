#!/usr/bin/env bash
# How many more Dev+Tester pairs fit on this machine now and what limits it; the other large consumers; what cannot be
# measured; and, for each worktree given, what it runs and how many more fit there.  Read-only: it never calls Orca and
# never writes anything.
# Usage:  capacity.sh [--json] [<worktree folder>...]     (no folder: the current one, when it has an orca-roles team)
#   The machine part reads the configuration of ORCA_ROLES_CONFIG when set, else of the first worktree (its
#   orca-roles.config.json), else the kit's config.json, else its config.default.json; each row uses its own worktree's.
#   Without a folder ORCA_ROLES_STATE and ORCA_ROLES_CONFIG apply as in team-status.sh.
#   Lines in this order: "Capacity:", "Memory:", "CPU:", "Footprints:", "Orca:" (when an Orca process is found),
#   "Large consumers:" (when there are some) and one "Not measured:" per item; then one "Worktree <path>:" per folder.
#   --json   one JSON object instead (os, load1, cores, maxLoad, pairLoad, availableMB, minFreeMemoryMB, pairMB,
#            footprints, footprintKind, pairs, orcaMB, consumers, notMeasured, worktrees)
# Exit 0 after a measure; 2 for an unknown option or a folder argument that is not a folder.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
JSON=0; ND=0; DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1;;
    -h|--help) sed -n 2,13p "$0"; exit 0;;
    -*) echo "capacity.sh: unknown option $1" >&2; exit 2;;
    *) DIRS[ND]="$1"; ND=$((ND + 1));;
  esac
  shift
done
cfg_int() {  # cfg_int <config file> <jq filter> <default>: a whole number from the configuration, or the default
  local v; v="$(jq -r "$2" "$1" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$3";; *) printf '%s\n' "$v";; esac
}
cfg_num() {  # cfg_num <config file> <jq filter> <default>: a number above 0 from the configuration, or the default
  local v; v="$(jq -r "$2" "$1" 2>/dev/null)"
  case "$v" in ''|*[!0-9.]*|*.*.*|.) printf '%s\n' "$3"; return 0;; esac
  if awk -v x="$v" 'BEGIN { exit !(x + 0 > 0) }'; then printf '%s\n' "$v"; else printf '%s\n' "$3"; fi
}
tabs_of() {  # tabs_of <state file> <ROLE VAR>: the saved tabs of the role and of its instances (DEV, DEV_2, ...), with a value
  awk -F= -v r="$2" '($1 == r || $1 ~ "^" r "_[0-9]+$") && $2 != "" { n++ } END { print n + 0 }' "$1"
}
pairs_of() {  # pairs_of <registry>: the pair trees still open or integrated
  awk -F'\t' '$NF == "open" || $NF == "integrated" { n++ } END { print n + 0 }' "$1"
}
jnum() {  # jnum <value>: a JSON number, or null for a value the system did not give
  if [ -z "$1" ] || [ "$1" = - ]; then printf 'null'; else printf '%s' "$1"; fi
}
fp_src() {  # fp_src <tabs>: where a footprint came from
  if [ "$1" -gt 0 ]; then printf 'average of %s live tab(s)' "$1"; else printf 'default estimate, no live tab'; fi
}
NP=0; RPATH=(); RGIT=(); RSTATE=(); RCFG=(); RTEAM=()
add_row() {  # add_row <folder> <git dir> <state file> <config file>
  RPATH[NP]="$1"; RGIT[NP]="$2"; RSTATE[NP]="$3"; RCFG[NP]="$4"
  if [ -n "$2" ] && [ -s "$3" ]; then RTEAM[NP]=1; else RTEAM[NP]=0; fi
  NP=$((NP + 1))
}
if [ "$ND" = 0 ]; then
  d="$(cd . 2>/dev/null && pwd -P)" || d="$PWD"
  g="$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || g=""
  if [ -n "$g" ]; then
    st="${ORCA_ROLES_STATE:-$g/orca-roles.env}"
    [ ! -s "$st" ] || add_row "$d" "$g" "$st" "${ORCA_ROLES_CONFIG:-$g/orca-roles.config.json}"
  fi
else
  i=0
  while [ "$i" -lt "$ND" ]; do
    a="${DIRS[i]}"
    d="$(cd "$a" 2>/dev/null && pwd -P)" || { echo "capacity.sh: $a is not a folder" >&2; exit 2; }
    g="$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || g=""
    st=""; cf=""
    [ -z "$g" ] || { st="$g/orca-roles.env"; cf="$g/orca-roles.config.json"; }
    add_row "$d" "$g" "$st" "$cf"
    i=$((i + 1))
  done
fi
MCFG=""
[ -z "${ORCA_ROLES_CONFIG:-}" ] || MCFG="$ORCA_ROLES_CONFIG"
if [ -z "$MCFG" ] && [ "$NP" -gt 0 ] && [ "${RTEAM[0]}" = 1 ] && [ -f "${RGIT[0]}/orca-roles.config.json" ]; then MCFG="${RGIT[0]}/orca-roles.config.json"; fi
[ -n "$MCFG" ] || MCFG="$KIT/config.json"
[ -f "$MCFG" ] || MCFG="$KIT/config.default.json"
[ -f "$MCFG" ] || MCFG=/dev/null
MFREE="$(cfg_int "$MCFG" '.settings.scaling.minFreeMemoryMB // 2048' 2048)"
MAXLOAD="$(cfg_num "$MCFG" '.settings.scaling.maxLoad // 0.8' 0.8)"
DAGENT="$(rstr "$MCFG" dev agent 2>/dev/null)"; DAGENT="${DAGENT:-claude}"
TAGENT="$(rstr "$MCFG" tester agent 2>/dev/null)"; TAGENT="${TAGENT:-claude}"
OS="$(host_os)"
TABLE="$(proc_table)"; KIND="$(proc_kind)"
read -r CMB CN <<< "$(agent_tab_mb claude "$TABLE")"
read -r OMB ON <<< "$(agent_tab_mb opencode "$TABLE")"
read -r XMB XN <<< "$(agent_tab_mb codex "$TABLE")"
read -r DMB _ <<< "$(agent_tab_mb "$DAGENT" "$TABLE")"
read -r TMB _ <<< "$(agent_tab_mb "$TAGENT" "$TABLE")"
PAIRMB=$((DMB + TMB)); PAIRLOAD=1.0
read -r LOAD CORES AVAIL <<< "$(host_capacity)"
case "$LOAD" in ''|*[!0-9.]*|*.*.*) LOAD=-;; esac
case "$CORES" in ''|*[!0-9]*) CORES=-;; esac
case "$AVAIL" in ''|*[!0-9]*) AVAIL=-;; esac
read -r BYMEM BYCPU FIT LIMIT <<< "$(pair_capacity "$AVAIL" "$MFREE" "$PAIRMB" "$LOAD" "$CORES" "$MAXLOAD")"
TABPIDS=""
[ -z "$TABLE" ] || TABPIDS="$(proc_tabs "$TABLE" | awk -F'\t' '$1 ~ /^[0-9]+$/ { printf "%s%s", (n++ ? " " : ""), $1 }')"
STATS="$(printf '%s\n' "$TABLE" | awk -F'\t' -v os="$OS" -v tabs="$TABPIDS" '
  function bname(s) { sub(/.*\//, "", s); return s }
  function jesc(s,  t) { t = s; gsub(/\\/, "\\\\", t); gsub(/"/, "\\\"", t); return t }
  BEGIN { n = split(tabs, a, " "); for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9]+$/) T[a[i] + 0] = 1 }
  $1 ~ /^[0-9]+$/ { p = $1 + 0; P[p] = $2 + 0; M[p] = $3 + 0; X[p] = $4; ID[++cnt] = p }
  END {
    orca = 0; found = 0
    for (i = 1; i <= cnt; i++) {
      p = ID[i]
      if (os == "macos") { if (index(X[p], "/Orca.app/") > 0 || index(X[p], "/Orca Agents.app/") > 0) { orca += M[p]; found = 1; O[p] = 1 } }
      else if (os == "linux") { b = bname(X[p]); if (b == "orca" || b == "Orca") { orca += M[p]; found = 1; O[p] = 1 } }
    }
    for (i = 1; i <= cnt; i++) {
      p = ID[i]
      if (p in T) { TREE[p] = 1; continue }
      x = P[p]; seen = 0
      while (x != 0 && seen < 1000) { seen++; if (x in T) { TREE[p] = 1; break }; if (!(x in P)) break; x = P[x] }
    }
    k = 0
    for (i = 1; i <= cnt; i++) { p = ID[i]; if ((p in TREE) || (p in O) || M[p] < 1024) continue; CP[++k] = p }
    for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) if (M[CP[j]] > M[CP[i]] || (M[CP[j]] == M[CP[i]] && bname(X[CP[j]]) < bname(X[CP[i]]))) { q = CP[i]; CP[i] = CP[j]; CP[j] = q }
    s = ""
    for (i = 1; i <= k && i <= 3; i++) s = s (i > 1 ? "," : "") "{\"name\":\"" jesc(bname(X[CP[i]])) "\",\"mb\":" M[CP[i]] "}"
    printf "orca\t%d\t%d\ncons\t[%s]\n", found, orca, s
  }')"
ORCAM=""; CONSJ='[]'
while IFS=$'\t' read -r k v1 v2; do
  case "$k" in
    orca) if [ "$v1" = 1 ]; then ORCAM="$v2"; fi;;
    cons) CONSJ="${v1:-[]}";;
  esac
done <<EOF
$STATS
EOF
[ -n "$CONSJ" ] || CONSJ='[]'
NOTM='[]'
add_notm() { NOTM="$(printf '%s' "$NOTM" | jq -c --arg s "$1" '. + [$s]' 2>/dev/null)"; [ -n "$NOTM" ] || NOTM='[]'; }
[ "$OS" != wsl ] || add_notm "the Windows side (Orca, the Windows apps and the memory Windows keeps for itself); the numbers are the WSL VM's, within its .wslconfig memory limit"
[ "$AVAIL" != - ] || add_notm "the memory (the system gave no available memory)"
{ [ "$LOAD" != - ] && [ "$CORES" != - ]; } || add_notm "the load (the system gave no load or no core count)"
[ -n "$KIND" ] || add_notm "process footprints on this system"
CONSLINE="$(printf '%s' "$CONSJ" | jq -r --arg vm " (a virtual machine, such as Docker Desktop's)" 'map("\(.name)\(if (.name | contains("Virtualization.VirtualMachine")) then $vm else "" end) \(.mb) MB") | join(", ")' 2>/dev/null)"
WT='[]'; ROW=()
i=0
while [ "$i" -lt "$NP" ]; do
  if [ "${RTEAM[i]}" = 1 ]; then
    st="${RSTATE[i]}"; cf="${RCFG[i]}"; [ -f "$cf" ] || cf=/dev/null
    pr="${RGIT[i]}/orca-roles.pairs"; [ -f "$pr" ] || pr=/dev/null
    dev="$(tabs_of "$st" DEV)"; tst="$(tabs_of "$st" TESTER)"; ptr="$(pairs_of "$pr")"
    run=$((dev > tst ? dev : tst))
    emax="$(cfg_int "$cf" '.settings.scaling.maxExtraInstances // 4' 4)"
    extras="$(instance_tabs "$cf" "$st" dev 2>/dev/null | awk '{ print $2 + 0 }')"; extras="${extras:-0}"
    if [ "$extras" -ge "$emax" ]; then cap1=0; else cap1=$(((emax - extras) / 2)); fi
    mx="$(max_instances "$cf" dev)"; [ -n "$mx" ] || mx=1; cap2=$((mx - dev)); [ "$cap2" -ge 0 ] || cap2=0
    mx="$(max_instances "$cf" tester)"; [ -n "$mx" ] || mx=1; cap3=$((mx - tst)); [ "$cap3" -ge 0 ] || cap3=0
    rda="$(rstr "$cf" dev agent 2>/dev/null)"; rda="${rda:-claude}"
    rta="$(rstr "$cf" tester agent 2>/dev/null)"; rta="${rta:-claude}"
    read -r rdmb _ <<< "$(agent_tab_mb "$rda" "$TABLE")"
    read -r rtmb _ <<< "$(agent_tab_mb "$rta" "$TABLE")"
    rmfree="$(cfg_int "$cf" '.settings.scaling.minFreeMemoryMB // 2048' 2048)"
    rmax="$(cfg_num "$cf" '.settings.scaling.maxLoad // 0.8' 0.8)"
    read -r _ _ rf rl <<< "$(pair_capacity "$AVAIL" "$rmfree" "$((rdmb + rtmb))" "$LOAD" "$CORES" "$rmax")"
    if [ "$rf" = - ]; then rmeas=0; val=""; name=""; else rmeas=1; val="$rf"; name="$rl"; fi
    if [ -z "$val" ] || [ "$cap1" -le "$val" ]; then val="$cap1"; name=maxExtraInstances; fi
    if [ "$cap2" -le "$cap3" ]; then capx="$cap2"; else capx="$cap3"; fi
    if [ -z "$val" ] || [ "$capx" -lt "$val" ]; then val="$capx"; name=maxInstances; fi
    WT="$(printf '%s' "$WT" | jq -c --arg p "${RPATH[i]}" --argjson d "$dev" --argjson t "$tst" --argjson pt "$ptr" --argjson r "$run" --argjson m "$val" --arg l "$name" --argjson mm "$rmeas" '. + [{path: $p, team: true, devTabs: $d, testerTabs: $t, pairTrees: $pt, running: $r, moreHere: $m, limit: $l, machineMeasured: ($mm == 1)}]')"
    rowline="Worktree ${RPATH[i]}: $run pair(s) running ($dev Dev tab(s), $tst Tester tab(s), $ptr pair tree(s)); $val more fit here (limited by $name)."
    [ "$rmeas" = 1 ] || rowline="$rowline The machine was not measured."
  else
    WT="$(printf '%s' "$WT" | jq -c --arg p "${RPATH[i]}" '. + [{path: $p, team: false}]')"
    rowline="Worktree ${RPATH[i]}: no team."
  fi
  ROW[i]="$rowline"
  i=$((i + 1))
done
OBJ="$(jq -n \
  --arg os "$OS" --argjson load1 "$(jnum "$LOAD")" \
  --argjson cores "$(jnum "$CORES")" \
  --argjson maxLoad "$MAXLOAD" --argjson pairLoad "$PAIRLOAD" \
  --argjson availableMB "$(jnum "$AVAIL")" \
  --argjson minFreeMemoryMB "$MFREE" --argjson pairMB "$PAIRMB" \
  --argjson cmb "$CMB" --argjson cn "$CN" --argjson omb "$OMB" --argjson on "$ON" --argjson xmb "$XMB" --argjson xn "$XN" \
  --arg kind "$KIND" \
  --argjson bymem "$(jnum "$BYMEM")" \
  --argjson bycpu "$(jnum "$BYCPU")" \
  --argjson fit "$(jnum "$FIT")" \
  --arg lim "$LIMIT" \
  --argjson orca "$(jnum "$ORCAM")" \
  --argjson cons "$CONSJ" --argjson notm "$NOTM" --argjson wts "$WT" \
  '{os: $os, load1: $load1, cores: $cores, maxLoad: $maxLoad, pairLoad: $pairLoad, availableMB: $availableMB,
    minFreeMemoryMB: $minFreeMemoryMB, pairMB: $pairMB,
    footprints: {claude: {mb: $cmb, tabs: $cn, source: (if $cn > 0 then "measured" else "default" end)},
                 opencode: {mb: $omb, tabs: $on, source: (if $on > 0 then "measured" else "default" end)},
                 codex: {mb: $xmb, tabs: $xn, source: (if $xn > 0 then "measured" else "default" end)}},
    footprintKind: (if $kind == "" then null else $kind end),
    pairs: {byMemory: $bymem, byCpu: $bycpu, fit: $fit, limit: $lim},
    orcaMB: $orca, consumers: $cons, notMeasured: $notm, worktrees: $wts}')"
if [ "$JSON" = 1 ]; then
  printf '%s\n' "$OBJ"
  exit 0
fi
if [ "$FIT" = - ]; then
  printf 'Capacity: unknown (neither the memory nor the load could be read).\n'
else
  printf 'Capacity: %s more Dev+Tester pair(s) fit now (limited by %s).\n' "$FIT" "$LIMIT"
fi
if [ "$AVAIL" = - ]; then
  printf 'Memory: not measured.\n'
else
  printf 'Memory: %s MB available, %s MB kept free (settings.scaling.minFreeMemoryMB), %s MB per pair (Dev %s %s MB, Tester %s %s MB): %s pair(s).\n' "$AVAIL" "$MFREE" "$PAIRMB" "$DAGENT" "$DMB" "$TAGENT" "$TMB" "$BYMEM"
fi
if [ "$LOAD" = - ] || [ "$CORES" = - ]; then
  printf 'CPU: not measured.\n'
else
  printf 'CPU: load %s on %s cores, settings.scaling.maxLoad %s per core, %s per pair: %s pair(s).\n' "$LOAD" "$CORES" "$MAXLOAD" "$PAIRLOAD" "$BYCPU"
fi
printf 'Footprints: claude %s MB (%s); opencode %s MB (%s); codex %s MB (%s).' "$CMB" "$(fp_src "$CN")" "$OMB" "$(fp_src "$ON")" "$XMB" "$(fp_src "$XN")"
if [ "$KIND" = rss ]; then printf ' Measured as RSS.'; fi
printf '\n'
if [ "$OS" != wsl ] && [ -n "$ORCAM" ]; then printf 'Orca: %s MB.\n' "$ORCAM"; fi
if [ -n "$CONSLINE" ]; then printf 'Large consumers: %s.\n' "$CONSLINE"; fi
printf '%s' "$NOTM" | jq -r '.[] | "Not measured: \(.)."' 2>/dev/null
i=0
while [ "$i" -lt "$NP" ]; do printf '%s\n' "${ROW[i]}"; i=$((i + 1)); done
exit 0
