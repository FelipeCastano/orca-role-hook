#!/usr/bin/env bash
# Searches scholarly sources (OpenAlex, arXiv, Semantic Scholar) and reads one paper's metadata. Only curl, jq and awk are needed.
# Usage:
#   scholar.sh search "<query>" [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--type article|proceedings|preprint] [--publisher <name>]
#                      [--venue <name>] [--oa] [--sort relevance|date|citations] [--limit N] [--source openalex|arxiv|s2|all]
#       One TAB-separated line per result after a header: source id year first_author venue citations oa title.
#       --limit is per source (1-100, default 10). A source that cannot honour an option is skipped with a note under --source all.
#   scholar.sh show <identifier>
#       Prints "key: value" lines: id title year date type authors venue publisher doi arxiv citations oa oa_url retracted abstract.
#   Identifiers: doi:<doi>, https://doi.org/<doi>, a bare 10.* DOI, arxiv:<id>, https://arxiv.org/abs/<id>, openalex:W<digits>.
#   Output ids: doi:<doi>, arxiv:<id>, openalex:W<id>, s2:<paperId> (output only).
# Environment (read only, never printed): OPENALEX_API_KEY and S2_API_KEY (optional, sent as headers), SCHOLAR_EMAIL (optional, goes in
#   the User-Agent). Test hooks: SCHOLAR_CURL, SCHOLAR_ARXIV_DELAY (default 3), SCHOLAR_RETRY_DELAY (default 3), SCHOLAR_STATE_DIR.
# Exit codes: 0 ok; 1 usage error or bad option; 2 not found (show); 3 network/API error (every requested source failed).
set -uo pipefail
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; "") usage >&2; exit 1;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
AXAWK="$HERE/scholar-arxiv.awk"
UA="orca-roles-scholar"
[ -n "${SCHOLAR_EMAIL:-}" ] && UA="orca-roles-scholar (mailto:$SCHOLAR_EMAIL)"
STATE_DIR="${SCHOLAR_STATE_DIR:-${TMPDIR:-/tmp}}"
OA_SELECT="id,doi,title,publication_year,type,authorships,primary_location,cited_by_count,open_access"
OA_SELECT_SHOW="id,doi,title,publication_year,publication_date,type,authorships,primary_location,cited_by_count,open_access,is_retracted,abstract_inverted_index"
S2_FIELDS="title,year,externalIds,authors,venue,citationCount,isOpenAccess"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/scholar.XXXXXX")" || { echo "scholar.sh: cannot create a temp dir" >&2; exit 3; }
trap 'rm -rf "$TMP"' EXIT

die() { echo "scholar.sh: $*" >&2; exit "${CODE:-1}"; }

# http_get <url> <body-file> [extra curl args...]: prints the HTTP status (000 when curl fails)
http_get() {
  local url="$1" out="$2" code; shift 2
  : > "$out"
  local follow=-L; [ -n "${NOFOLLOW:-}" ] && follow=""
  # shellcheck disable=SC2086
  code="$("${SCHOLAR_CURL:-curl}" -sS $follow --max-time 30 -A "$UA" -o "$out" -w '%{http_code}' "$@" "$url" 2>/dev/null)" || code=000
  case "$code" in [0-9][0-9][0-9]) ;; *) code=000;; esac
  printf '%s' "$code"
}

# api_get <openalex|s2> <url> <body-file> [nokey]: http_get with the key header (from a file) and 429 retries
api_get() {
  local kind="$1" url="$2" out="$3" nokey="${4:-}" hf="" try=0 code d="${SCHOLAR_RETRY_DELAY:-3}"
  if [ -z "$nokey" ]; then
    if [ "$kind" = openalex ] && [ -n "${OPENALEX_API_KEY:-}" ]; then
      hf="$TMP/h.openalex"; (umask 077; printf 'Authorization: Bearer %s\n' "$OPENALEX_API_KEY" > "$hf")
    elif [ "$kind" = s2 ] && [ -n "${S2_API_KEY:-}" ]; then
      hf="$TMP/h.s2"; (umask 077; printf 'x-api-key: %s\n' "$S2_API_KEY" > "$hf")
    fi
  fi
  while :; do
    if [ -n "$hf" ]; then code="$(NOFOLLOW=1 http_get "$url" "$out" -H "@$hf")"; else code="$(http_get "$url" "$out")"; fi
    if [ "$code" = 429 ] && [ "$try" -lt 2 ]; then
      try=$((try + 1)); sleep "$(awk -v d="$d" -v t="$try" 'BEGIN{print d*t}')"
    else
      break
    fi
  done
  printf '%s' "$code"
}

# arxiv_get <url> <body-file>: paced (one call every SCHOLAR_ARXIV_DELAY seconds across runs), never retried
arxiv_get() {
  local url="$1" out="$2" f="$STATE_DIR/orca-roles-scholar-arxiv.last" d="${SCHOLAR_ARXIV_DELAY:-3}" last now code
  case "$d" in ''|*[!0-9]*) d=3;; esac
  if [ "$d" -gt 0 ] && [ -f "$f" ]; then
    last="$(cat "$f" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) ;; *)
      now="$(date +%s)"
      [ "$now" -ge "$last" ] && [ $((now - last)) -lt "$d" ] && sleep $((d - (now - last)));;
    esac
  fi
  code="$(http_get "$url" "$out")"
  date +%s > "$f" 2>/dev/null
  printf '%s' "$code"
}

# parse_id <identifier>: sets ID_KIND (doi|arxiv|openalex) and ID_VAL
parse_id() {
  local x="$1" low v
  low="$(printf '%s' "$x" | tr 'A-Z' 'a-z')"
  ID_KIND=""; ID_VAL=""
  case "$low" in
    doi:*) v="${x#????}"; ID_KIND=doi;;
    https://doi.org/*) v="${x#https://doi.org/}"; ID_KIND=doi;;
    http://doi.org/*) v="${x#http://doi.org/}"; ID_KIND=doi;;
    10.*) v="$x"; ID_KIND=doi;;
    arxiv:*) v="${x#??????}"; ID_KIND=arxiv;;
    https://arxiv.org/abs/*) v="${x#https://arxiv.org/abs/}"; ID_KIND=arxiv;;
    openalex:w[0-9]*) v="$(printf '%s' "${x#?????????}" | tr 'w' 'W')"; ID_KIND=openalex;;
  esac
  [ -n "$ID_KIND" ] || return 1
  v="$(printf '%s' "$v" | tr -d ' ')"
  case "$ID_KIND" in
    doi)
      case "$v" in 10.?*/?*) ;; *) return 1;; esac
      v="$(printf '%s' "$v" | tr 'A-Z' 'a-z')"
      if [[ "$v" =~ ^10\.48550/arxiv\.(.+)$ ]]; then ID_KIND=arxiv; v="${BASH_REMATCH[1]}"; fi;;
    openalex) [[ "$v" =~ ^W[0-9]+$ ]] || return 1;;
  esac
  if [ "$ID_KIND" = arxiv ]; then
    v="$(printf '%s' "$v" | sed 's/v[0-9][0-9]*$//')"
    [[ "$v" =~ ^[A-Za-z0-9./-]+$ ]] || return 1
  fi
  ID_VAL="$v"
}

# jq prelude shared by the OpenAlex parsers
JQ_DEFS='
def c: if . == null then "-" else (tostring | gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "")) end | if . == "" then "-" else . end;
def yn: if . == true then "yes" else "no" end;
def oaid: if .doi then (.doi | sub("^https?://doi.org/"; "") | ascii_downcase) as $d
    | (if ($d | test("^10\\.48550/arxiv\\."; "i")) then "arxiv:" + ($d | sub("^10\\.48550/arxiv\\."; "") | sub("v[0-9]+$"; "")) else "doi:" + $d end)
  else "openalex:" + (.id | sub("^https://openalex.org/"; "")) end;
'

venue_alias() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    neurips|nips) echo "Neural Information Processing Systems";;
    icml) echo "International Conference on Machine Learning";;
    iclr) echo "International Conference on Learning Representations";;
    acl) echo "Annual Meeting of the Association for Computational Linguistics";;
    emnlp) echo "Conference on Empirical Methods in Natural Language Processing";;
    cvpr) echo "Computer Vision and Pattern Recognition";;
    aaai) echo "AAAI Conference on Artificial Intelligence";;
    ijcai) echo "International Joint Conference on Artificial Intelligence";;
    *) printf '%s\n' "$1";;
  esac
}

# resolve_oa <publisher|venue> <name>: sets RESOLVED_ID, notes on stderr
resolve_oa() {
  local kind="$1" name="$2" q url code body="$TMP/resolve.json" out target
  if [ "$kind" = venue ]; then target="$(venue_alias "$name")"; else target="$name"; fi
  q="$(jq -rn --arg q "$target" '$q | @uri')"
  if [ "$kind" = publisher ]; then
    url="https://api.openalex.org/publishers?search=$q&per_page=25&select=id,display_name,lineage,works_count"
  else
    url="https://api.openalex.org/sources?search=$q&per_page=10&select=id,display_name,works_count"
  fi
  code="$(api_get openalex "$url" "$body")"
  if [ "$code" != 200 ]; then CODE=3 die "OpenAlex failed (HTTP $code) while resolving the $kind '$name'"; fi
  out="$(jq -r --arg kind "$kind" --arg n "$target" '
    def sid: sub("^https://openalex.org/"; "");
    [.results[]?] | sort_by(-(.works_count // 0)) as $r
    | if ($r | length) == 0 then empty else
      (if $kind == "venue" then (($r | map(select((.display_name // "" | ascii_downcase) == ($n | ascii_downcase))) | .[0]) // $r[0]) else $r[0] end) as $p
      | "PICK\t" + ($p.display_name // "-") + "\t" + (if $kind == "publisher" then (($p.lineage // [$p.id])[-1] | sid) else ($p.id | sid) end),
        ([$r[] | select(.id != $p.id)][:2] | map((.display_name // "-") + " (" + (.id | sid) + ")") | if length > 0 then "OTH\t" + join(", ") else empty end)
      end' "$body" 2>/dev/null)"
  [ -n "$out" ] || die "no OpenAlex $kind matches '$name'"
  RESOLVED_ID="$(printf '%s\n' "$out" | awk -F'\t' '$1=="PICK"{print $3}')"
  echo "note: $kind '$name' -> $(printf '%s\n' "$out" | awk -F'\t' '$1=="PICK"{print $2}') ($RESOLVED_ID)" >&2
  printf '%s\n' "$out" | awk -F'\t' '$1=="OTH"{print "note: other candidates: " $2}' >&2
}

search_openalex() {
  local q filters="" sort url code body="$TMP/oa.json"
  q="$(jq -rn --arg q "$QUERY" '$q | @uri')"
  [ -n "$FROM" ] && filters="$filters,from_publication_date:$FROM"
  [ -n "$TO" ] && filters="$filters,to_publication_date:$TO"
  case "$TYPE" in article) filters="$filters,type:article";; proceedings) filters="$filters,type:conference-paper";; preprint) filters="$filters,type:preprint";; esac
  [ "$OA" = 1 ] && filters="$filters,is_oa:true"
  if [ -n "$PUBLISHER" ]; then resolve_oa publisher "$PUBLISHER"; filters="$filters,primary_location.source.publisher_lineage:$RESOLVED_ID"; fi
  if [ -n "$VENUE" ]; then resolve_oa venue "$VENUE"; filters="$filters,primary_location.source.id:$RESOLVED_ID"; fi
  case "$SORT" in relevance) sort="relevance_score:desc";; date) sort="publication_date:desc";; citations) sort="cited_by_count:desc";; esac
  url="https://api.openalex.org/works?search=$q"
  [ -n "$filters" ] && url="$url&filter=${filters#,}"
  url="$url&sort=$sort&per_page=$LIMIT&select=$OA_SELECT"
  code="$(api_get openalex "$url" "$body")"
  if [ "$code" != 200 ]; then SRC_CODE="$code"; return 1; fi
  jq -r --argjson lim "$LIMIT" "$JQ_DEFS"'
    (.results // [])[:$lim][] | [ "openalex", (oaid | c), (.publication_year | c), (.authorships[0].author.display_name | c),
      (.primary_location.source.display_name | c), (.cited_by_count | c), (.open_access.is_oa | yn), (.title | c) ] | join("\t")' "$body" > "$TMP/res.openalex" 2>/dev/null \
    || { SRC_CODE="$code"; return 1; }
}

ax_error() { head -n 1 "$TMP/ax.err" | sed 's/^ERROR[[:space:]]*//'; }

search_arxiv() {
  local sq code body="$TMP/ax.xml" sortby a b
  sq="$(jq -rn --arg q "$QUERY" '$q | [splits("\\s+") | select(length > 0) | "all:" + @uri] | join("+AND+")')"
  if [ -n "$FROM$TO" ]; then
    a="${FROM:-1991-01-01}"; b="${TO:-2099-12-31}"
    sq="$sq+AND+submittedDate:%5B$(printf '%s' "$a" | tr -d -)0000+TO+$(printf '%s' "$b" | tr -d -)2359%5D"
  fi
  case "$SORT" in
    date) sortby=submittedDate;;
    citations) sortby=relevance; echo "note: arxiv has no citation counts; sorted by relevance" >&2;;
    *) sortby=relevance;;
  esac
  code="$(arxiv_get "https://export.arxiv.org/api/query?search_query=$sq&start=0&max_results=$LIMIT&sortBy=$sortby&sortOrder=descending" "$body")"
  if [ "$code" != 200 ]; then SRC_CODE="$code"; return 1; fi
  awk -f "$AXAWK" "$body" > "$TMP/ax.tsv" 2> "$TMP/ax.err"
  if [ -s "$TMP/ax.err" ]; then SRC_MSG="returned an error: $(ax_error)"; return 1; fi
  awk -F'\t' -v OFS='\t' -v lim="$LIMIT" '
    function f(x) { return x == "" ? "-" : x }
    NR <= lim { au = $10; p = index(au, "; "); if (p > 0) au = substr(au, 1, p - 1)
      print "arxiv", "arxiv:" $1, f(substr($4, 1, 4)), f(au), "arXiv " f($8), "-", "yes", f($3) }' "$TMP/ax.tsv" > "$TMP/res.arxiv"
}

search_s2() {
  local q url code body="$TMP/s2.json" f="" sort
  [ -n "$FROM$TO" ] && f="$f&publicationDateOrYear=$FROM:$TO"
  case "$TYPE" in article) f="$f&publicationTypes=JournalArticle";; proceedings) f="$f&publicationTypes=Conference";; esac
  [ "$OA" = 1 ] && f="$f&openAccessPdf"
  [ -n "$VENUE" ] && f="$f&venue=$(jq -rn --arg q "$VENUE" '$q | @uri')"
  if [ -n "${S2_API_KEY:-}" ] && [ "$SORT" = relevance ]; then
    q="$(jq -rn --arg q "${QUERY//-/ }" '$q | @uri')"
    url="https://api.semanticscholar.org/graph/v1/paper/search?query=$q&limit=$LIMIT&fields=$S2_FIELDS$f"
  else
    q="$(jq -rn --arg q "$QUERY" '$q | @uri')"
    case "$SORT" in
      date) sort="publicationDate:desc";;
      citations) sort="citationCount:desc";;
      *) sort="citationCount:desc"; echo "note: Semantic Scholar without S2_API_KEY has no relevance ranking; sorted by citations" >&2;;
    esac
    url="https://api.semanticscholar.org/graph/v1/paper/search/bulk?query=$q&fields=$S2_FIELDS&sort=$sort$f"
  fi
  code="$(api_get s2 "$url" "$body")"
  if [ "$code" = 403 ] && [ -n "${S2_API_KEY:-}" ]; then
    echo "warning: S2_API_KEY was rejected; retried without it" >&2
    code="$(api_get s2 "$url" "$body" nokey)"
  fi
  if [ "$code" != 200 ]; then SRC_CODE="$code"; return 1; fi
  jq -r --argjson lim "$LIMIT" "$JQ_DEFS"'
    def s2id: (.externalIds // {}) as $e
      | if $e.DOI then ($e.DOI | ascii_downcase) as $d
          | (if ($d | test("^10\\.48550/arxiv\\."; "i")) then "arxiv:" + ($d | sub("^10\\.48550/arxiv\\."; "") | sub("v[0-9]+$"; "")) else "doi:" + $d end)
        elif $e.ArXiv then "arxiv:" + ($e.ArXiv | sub("v[0-9]+$"; ""))
        else "s2:" + .paperId end;
    (.data // [])[:$lim][] | [ "s2", (s2id | c), (.year | c), (.authors[0].name | c), (.venue | c), (.citationCount | c), (.isOpenAccess | yn), (.title | c) ] | join("\t")' \
    "$body" > "$TMP/res.s2" 2>/dev/null || { SRC_CODE="$code"; return 1; }
}

cmd_search() {
  QUERY=""; FROM=""; TO=""; TYPE=""; PUBLISHER=""; VENUE=""; OA=0; SORT=relevance; LIMIT=10; SOURCE=all
  local seen=" " have_q=0 opt
  while [ $# -gt 0 ]; do
    case "$1" in
      --from|--to|--type|--publisher|--venue|--sort|--limit|--source)
        opt="$1"
        case "$seen" in *" $opt "*) die "option $opt given twice";; esac
        seen="$seen$opt "
        [ $# -ge 2 ] && [ -n "$2" ] || die "option $opt needs a value"
        case "$opt" in
          --from) FROM="$2";; --to) TO="$2";; --type) TYPE="$2";; --publisher) PUBLISHER="$2";;
          --venue) VENUE="$2";; --sort) SORT="$2";; --limit) LIMIT="$2";; --source) SOURCE="$2";;
        esac
        shift 2;;
      --oa)
        case "$seen" in *" --oa "*) die "option --oa given twice";; esac
        seen="$seen--oa "; OA=1; shift;;
      -*) die "unknown option '$1'";;
      *) [ "$have_q" = 0 ] || die "only one query is accepted (quote it)"; QUERY="$1"; have_q=1; shift;;
    esac
  done
  [ -n "$(printf '%s' "$QUERY" | tr -d '[:space:]')" ] || die "search needs a non-empty query"
  [ -z "$FROM" ] || [[ "$FROM" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--from must be YYYY-MM-DD"
  [ -z "$TO" ] || [[ "$TO" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--to must be YYYY-MM-DD"
  case "$TYPE" in ''|article|proceedings|preprint) ;; *) die "--type must be article, proceedings or preprint";; esac
  case "$SORT" in relevance|date|citations) ;; *) die "--sort must be relevance, date or citations";; esac
  case "$SOURCE" in openalex|arxiv|s2|all) ;; *) die "--source must be openalex, arxiv, s2 or all";; esac
  [[ "$LIMIT" =~ ^[0-9]+$ ]] && [ "$LIMIT" -ge 1 ] && [ "$LIMIT" -le 100 ] || die "--limit must be an integer between 1 and 100"
  LIMIT=$((10#$LIMIT))

  local sources="" s reason ran=0 okc=0 explicit=1
  [ "$SOURCE" = all ] && explicit=0
  if [ "$explicit" = 1 ]; then sources="$SOURCE"
  else sources="openalex arxiv"; [ -n "${S2_API_KEY:-}" ] && sources="$sources s2"; fi
  local run=""
  for s in $sources; do
    reason=""
    case "$s" in
      arxiv)
        case "$TYPE" in article|proceedings) reason="arXiv only has preprints";; esac
        [ -z "$reason" ] && { [ -n "$PUBLISHER" ] || [ -n "$VENUE" ]; } && reason="arXiv has no publisher/venue filter";;
      s2)
        [ "$TYPE" = preprint ] && reason="Semantic Scholar has no preprint type"
        [ -z "$reason" ] && [ -n "$PUBLISHER" ] && reason="Semantic Scholar has no publisher filter";;
    esac
    if [ -n "$reason" ]; then
      if [ "$explicit" = 1 ]; then die "--source $s: $reason"; fi
      echo "note: $s skipped: $reason" >&2
    else
      run="$run $s"
    fi
  done
  for s in $run; do
    ran=$((ran + 1)); SRC_CODE=""; SRC_MSG=""
    if "search_$s"; then okc=$((okc + 1)); else echo "warning: $s ${SRC_MSG:-failed (HTTP ${SRC_CODE:-000})}" >&2; rm -f "$TMP/res.$s"; fi
  done
  if [ "$okc" = 0 ]; then echo "scholar.sh: every source failed" >&2; return 3; fi
  printf 'source\tid\tyear\tfirst_author\tvenue\tcitations\toa\ttitle\n'
  for s in openalex arxiv s2; do [ -f "$TMP/res.$s" ] && cat "$TMP/res.$s"; done | awk -F'\t' '!seen[$2]++'
  return 0
}

cmd_show() {
  [ $# -eq 1 ] || die "show needs exactly one identifier"
  local ident="$1" code body="$TMP/show.body" url
  parse_id "$ident" || die "unrecognized identifier '$ident' (use doi:<doi>, arxiv:<id> or openalex:W<id>)"
  if [ "$ID_KIND" = arxiv ]; then
    code="$(arxiv_get "https://export.arxiv.org/api/query?id_list=$ID_VAL" "$body")"
    [ "$code" = 200 ] || { CODE=3 die "arXiv failed (HTTP $code)"; }
    awk -f "$AXAWK" "$body" > "$TMP/ax.tsv" 2> "$TMP/ax.err"
    [ ! -s "$TMP/ax.err" ] || { CODE=3 die "arXiv returned an error: $(ax_error)"; }
    [ -s "$TMP/ax.tsv" ] || { CODE=2 die "$ident not found in arXiv"; }
    awk -F'\t' '
      function f(x) { return x == "" ? "-" : x }
      NR == 1 { doi = tolower($6)
        print "id: arxiv:" $1; print "title: " f($3); print "year: " f(substr($4, 1, 4)); print "date: " f(substr($4, 1, 10))
        print "type: preprint"; print "authors: " f($10); print "venue: arXiv " f($8); print "publisher: -"; print "doi: " f(doi)
        print "arxiv: " $1; print "citations: -"; print "oa: yes"; print "oa_url: " f($9); print "retracted: -"; print "abstract: " f($11) }' "$TMP/ax.tsv"
    return 0
  fi
  if [ "$ID_KIND" = doi ]; then
    url="https://api.openalex.org/works/doi:$(printf '%s' "$ID_VAL" | sed -e 's/%/%25/g' -e 's/?/%3F/g' -e 's/#/%23/g' -e 's/ /%20/g')"
  else
    url="https://api.openalex.org/works/$ID_VAL"
  fi
  code="$(api_get openalex "$url?select=$OA_SELECT_SHOW" "$body")"
  [ "$code" != 404 ] || { CODE=2 die "$ident not found in OpenAlex"; }
  [ "$code" = 200 ] || { CODE=3 die "OpenAlex failed (HTTP $code)"; }
  jq -r "$JQ_DEFS"'
    (.abstract_inverted_index | if . == null then null
      else [to_entries[] | .key as $w | .value[] | {p: ., w: $w}] | sort_by(.p) | map(.w) | join(" ") | sub("^Abstract "; "") end) as $abs
    | "id: " + (oaid | c),
      "title: " + (.title | c),
      "year: " + (.publication_year | c),
      "date: " + (.publication_date | c),
      "type: " + (.type | c),
      "authors: " + ([.authorships[]?.author.display_name | select(. != null)] | join("; ") | c),
      "venue: " + (.primary_location.source.display_name | c),
      "publisher: " + (.primary_location.source.host_organization_name | c),
      "doi: " + (if .doi then (.doi | sub("^https?://doi.org/"; "") | ascii_downcase | c) else "-" end),
      "arxiv: " + (oaid | if startswith("arxiv:") then sub("^arxiv:"; "") else "-" end),
      "citations: " + (.cited_by_count | c),
      "oa: " + (.open_access.is_oa | yn),
      "oa_url: " + (.open_access.oa_url | c),
      "retracted: " + (.is_retracted | yn),
      "abstract: " + ($abs | c)' "$body" || { CODE=3 die "OpenAlex returned an unreadable body"; }
}

cmd="$1"; shift
case "$cmd" in
  search) cmd_search "$@"; exit $?;;
  show) cmd_show "$@"; exit $?;;
  *) die "unknown command '$cmd' (use search or show; -h for help)";;
esac
