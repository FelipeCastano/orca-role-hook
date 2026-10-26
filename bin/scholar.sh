#!/usr/bin/env bash
# Searches scholarly sources (OpenAlex, arXiv, Semantic Scholar) and reads one paper's metadata. Only curl, jq and awk are needed.
# Usage:
#   scholar.sh search "<query>" [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--type article|proceedings|preprint] [--publisher <name>]
#                      [--venue <name>] [--oa] [--sort relevance|date|citations] [--limit N] [--source openalex|arxiv|s2|all]
#       One TAB-separated line per result after a header: source id year first_author venue citations oa title.
#       --limit is per source (1-100, default 10). A source that cannot honour an option is skipped with a note under --source all.
#   scholar.sh show <identifier>
#       Prints "key: value" lines: id title year date type authors venue publisher doi arxiv citations oa oa_url retracted abstract.
#   scholar.sh bibtex <identifier> [--add] [--bib <path>]
#       Fetches the BibTeX entry of a DOI or arXiv id from doi.org and fixes it (key lastname+year+word, braced title, month macro, pages --).
#       Prints the entry. With --add it is appended to <path> (default <git top-level>/article/refs.bib, created if missing) and the key is
#       printed instead; a DOI already in the file is not added twice (its key is printed), a taken key gets b, c, ... appended.
#   scholar.sh verify [--bib <path>]
#       Checks every entry of the .bib (default <git top-level>/article/refs.bib) against Crossref or arXiv: title, first author, year and
#       retractions. Prints a header and one TAB-separated line per entry: key status detail.
#       Status: ok, warn, fail, retracted, notfound (DOI/arXiv id unknown), nodoi (no DOI or arXiv eprint), error (network/API).
#   scholar.sh pdf <identifier> [--bib <path>]
#       Gets the PDF of a paper that is in the .bib (default <git top-level>/article/refs.bib) into <git top-level>/article/literature/pdfs/<key>.pdf.
#       Sources, in order: arXiv (arxiv ids), Unpaywall (DOIs; only with SCHOLAR_EMAIL set), OpenAlex open_access.oa_url (DOIs). A download counts only
#       if it is a real PDF. Records the paper in article/literature/manifest.tsv (key id title pdf source; pdf is oa, manual or missing) and rewrites
#       article/literature/missing.md (the PDFs to download by hand). stdout: "downloaded <key> <file>", "present <key> <file>" (a valid PDF was already
#       there; no network call) or "missing <key> (listed in article/literature/missing.md)". Exit 0 got or present, 2 missing.
#   scholar.sh pdfs [--bib <path>]
#       Reconciles the manifest with the PDF folder (no network call): a missing paper whose PDF was dropped in becomes manual; an oa or manual paper whose
#       file is gone or is not a valid PDF becomes missing. Rewrites manifest.tsv and missing.md. Prints a header and one TAB-separated line per
#       paper: key pdf note (note: file gone, not a valid PDF, invalid key (a key that cannot be a file name; its row is kept unchanged) or -). Exit 1 when there is no manifest yet.
#   Identifiers: doi:<doi>, https://doi.org/<doi>, a bare 10.* DOI, arxiv:<id>, https://arxiv.org/abs/<id>, openalex:W<digits>.
#   Output ids: doi:<doi>, arxiv:<id>, openalex:W<id>, s2:<paperId> (output only).
# Environment (read only, never printed): OPENALEX_API_KEY and S2_API_KEY (optional, sent as headers), SCHOLAR_EMAIL (optional, goes in
#   the User-Agent (sent as a header read from a file) of the API calls that never follow redirects (OpenAlex, Semantic Scholar, arXiv API,
#   Crossref, Unpaywall) and in Unpaywall's email parameter; doi.org and PDF downloads follow redirects and always use the plain User-Agent
#   orca-roles-scholar). Test hooks: SCHOLAR_CURL, SCHOLAR_ARXIV_DELAY (default 3), SCHOLAR_RETRY_DELAY (default 3),
#   SCHOLAR_CROSSREF_DELAY (seconds between Crossref calls in verify, default 0.2), SCHOLAR_STATE_DIR.
# Exit codes: 0 ok; 1 usage error or bad option; 2 not found (show, bibtex); 3 network/API error (every requested source failed);
#   2 also: pdf found no PDF (the paper is listed in missing.md); 4 verify found problems (a fail, retracted, notfound or nodoi entry).
set -uo pipefail
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0;; "") usage >&2; exit 1;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
AXAWK="$HERE/scholar-arxiv.awk"
KEY_RE='^[A-Za-z0-9_.:+-]+$'
UA="orca-roles-scholar"
[ -n "${SCHOLAR_EMAIL:-}" ] && UA="orca-roles-scholar (mailto:$SCHOLAR_EMAIL)"
STATE_DIR="${SCHOLAR_STATE_DIR:-${TMPDIR:-/tmp}}"
OA_SELECT="id,doi,title,publication_year,type,authorships,primary_location,cited_by_count,open_access"
OA_SELECT_SHOW="id,doi,title,publication_year,publication_date,type,authorships,primary_location,cited_by_count,open_access,is_retracted,abstract_inverted_index"
S2_FIELDS="title,year,externalIds,authors,venue,citationCount,isOpenAccess"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/scholar.XXXXXX")" || { echo "scholar.sh: cannot create a temp dir" >&2; exit 3; }
trap 'rm -rf "$TMP"' EXIT

die() { echo "scholar.sh: $*" >&2; exit "${CODE:-1}"; }

# http_get <url> <body-file> [extra curl args...]: prints the HTTP status (000 when curl fails). Redirects are followed only when FOLLOW is set
# (doi.org and PDF downloads, which also set PLAIN_UA so the email never leaves with them). The User-Agent goes in a header file, never in -A.
http_get() {
  local url="$1" out="$2" code uaf="$TMP/ua.email" ua="$UA" follow=""; shift 2
  : > "$out"
  [ -z "${FOLLOW:-}" ] || follow=-L
  if [ -n "${PLAIN_UA:-}" ]; then uaf="$TMP/ua.plain"; ua="orca-roles-scholar"; fi
  [ -f "$uaf" ] || (umask 077; printf 'User-Agent: %s\n' "$ua" > "$uaf")
  # shellcheck disable=SC2086
  code="$("${SCHOLAR_CURL:-curl}" -sS $follow --max-time 30 -H "@$uaf" -o "$out" -w '%{http_code}' "$@" "$url" 2>/dev/null)" || code=000
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
    if [ -n "$hf" ]; then code="$(http_get "$url" "$out" -H "@$hf")"; else code="$(http_get "$url" "$out")"; fi
    if [ "$code" = 429 ] && [ "$try" -lt 2 ]; then
      try=$((try + 1)); sleep "$(awk -v d="$d" -v t="$try" 'BEGIN{print d*t}')"
    else
      break
    fi
  done
  printf '%s' "$code"
}

# arxiv_get <url> <body-file>: paced (one call every SCHOLAR_ARXIV_DELAY seconds across runs and processes; the whole-second stamp is taken
# before the call, so it waits d+1 whole seconds after the previous stamp), never retried. If the state dir is not a writable directory, or
# the lock cannot be taken (a stale one is removed once after 30 s), the call is made unpaced with a note on stderr (once per run).
arxiv_get() {
  local url="$1" out="$2" f="$STATE_DIR/orca-roles-scholar-arxiv.last" d="${SCHOLAR_ARXIV_DELAY:-3}" why=""; shift 2
  case "$d" in ''|*[!0-9]*) d=3;; esac
  if [ "$d" -gt 0 ]; then
    if [ ! -d "$STATE_DIR" ] || [ ! -w "$STATE_DIR" ]; then
      why="$STATE_DIR is not a writable directory"
    else
      (
        start="$(date +%s)"
        until mkdir "$f.lock" 2>/dev/null; do
          if [ $(($(date +%s) - start)) -ge "${SCHOLAR_STALE_LOCK_SECS:-30}" ]; then
            rmdir "$f.lock" 2>/dev/null
            mkdir "$f.lock" 2>/dev/null || exit 3
            break
          fi
          sleep 0.2
        done
        trap 'rmdir "$f.lock" 2>/dev/null' EXIT
        last="$(cat "$f" 2>/dev/null)"
        case "$last" in ''|*[!0-9]*) ;; *)
          now="$(date +%s)"
          [ "$now" -ge "$last" ] && [ $((now - last)) -le "$d" ] && sleep $((d + 1 - (now - last)));;
        esac
        date +%s > "$f" 2>/dev/null
        :
      ) || why="cannot take the lock $f.lock"
    fi
    if [ -n "$why" ] && [ ! -e "$TMP/arxiv.unpaced" ]; then
      : > "$TMP/arxiv.unpaced"
      echo "scholar.sh: arXiv calls are not paced: $why" >&2
    fi
  fi
  http_get "$url" "$out" "$@"
}

# parse_id <identifier>: sets ID_KIND (doi|arxiv|openalex) and ID_VAL
parse_id() {
  local x="$1" low v
  low="$(printf '%s' "$x" | tr 'A-Z' 'a-z')"
  ID_KIND=""; ID_VAL=""
  case "$low" in
    doi:*) v="${x#????}"; ID_KIND=doi;;
    https://doi.org/*) v="${x:16}"; ID_KIND=doi;;
    http://doi.org/*) v="${x:15}"; ID_KIND=doi;;
    10.*) v="$x"; ID_KIND=doi;;
    arxiv:*) v="${x#??????}"; ID_KIND=arxiv;;
    https://arxiv.org/abs/*) v="${x:22}"; ID_KIND=arxiv;;
    http://arxiv.org/abs/*) v="${x:21}"; ID_KIND=arxiv;;
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

# enc_doi <doi>: percent-encodes the characters that would break a URL path
enc_doi() { printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/?/%3F/g' -e 's/#/%23/g' -e 's/ /%20/g'; }

# default_bib: sets BIB_PATH to <git top-level>/article/refs.bib
default_bib() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  [ -n "$top" ] || die "not in a git repository; pass --bib <path>"
  BIB_PATH="$top/article/refs.bib"
}

# bibjq <program> [jq options...]: jq over the text on stdin (-Rs) with the bib helpers loaded
bibjq() { local prog="$1"; shift; jq -Rrs -L "$HERE" "$@" 'include "scholar-norm"; include "scholar-bibfix"; '"$prog"; }

cmd_bibtex() {
  local ident="" add=0 bib="" have_bib=0 doi code body="$TMP/bibtex.body" entry info base key n kf letter
  while [ $# -gt 0 ]; do
    case "$1" in
      --add) [ "$add" = 0 ] || die "option --add given twice"; add=1; shift;;
      --bib)
        [ "$have_bib" = 0 ] || die "option --bib given twice"
        [ $# -ge 2 ] && [ -n "$2" ] || die "option --bib needs a value"
        bib="$2"; have_bib=1; shift 2;;
      -*) die "unknown option '$1'";;
      *) [ -z "$ident" ] || die "bibtex needs exactly one identifier"; ident="$1"; shift;;
    esac
  done
  [ -n "$ident" ] || die "bibtex needs exactly one identifier"
  [ "$add" = 1 ] || [ "$have_bib" = 0 ] || die "--bib needs --add"
  parse_id "$ident" || die "unrecognized identifier '$ident' (use doi:<doi> or arxiv:<id>)"
  case "$ID_KIND" in
    openalex) die "bibtex needs a DOI or an arXiv id (run: scholar.sh show <id> to see its DOI)";;
    arxiv) doi="10.48550/arXiv.$ID_VAL";;
    *) doi="$ID_VAL";;
  esac
  if [ "$add" = 1 ]; then
    if [ "$have_bib" = 1 ]; then BIB_PATH="$bib"; else default_bib; fi
    [ ! -e "$BIB_PATH" ] || [ -f "$BIB_PATH" ] || die "$BIB_PATH is not a regular file"
  fi
  code="$(FOLLOW=1 PLAIN_UA=1 http_get "https://doi.org/$(enc_doi "$doi")" "$body" -H 'Accept: application/x-bibtex' -D "$TMP/bib.headers")"
  [ "$code" != 404 ] || { CODE=2 die "$ident not found at doi.org"; }
  if [ "$code" != 200 ] || [ "$(tr -d ' \t\r\n' < "$body" | head -c 1)" != "@" ] \
    || ! grep -i '^content-type:' "$TMP/bib.headers" 2>/dev/null | tail -n 1 | grep -qi 'application/x-bibtex'; then CODE=3 die "doi.org failed (HTTP $code)"; fi
  if [ "$(tr -d ' \t\r\n' < "$body" | tail -c 1)" != "}" ] \
    || ! tr -cd '{}' < "$body" | fold -w 1 | awk '$0 == "{" { d++ } $0 == "}" { if (--d < 0) bad = 1 } END { exit (bad || d != 0) }'; then
    CODE=3 die "doi.org returned an incomplete BibTeX entry"
  fi
  entry="$(jq -Rrs -L "$HERE" 'include "scholar-norm"; include "scholar-bibfix";
    sub("^\\s+"; "") | sub("\\s+$"; "") | . as $raw
    | ($raw | makekey(lastname; norm) | if . == "" then "ref" + ($raw | field("year") // "" | gsub("[^0-9]"; "")) else . end) as $k
    | $raw | rekey($k) | protect_title | fix_month | fix_pages' "$body")" || { CODE=3 die "doi.org returned an unreadable body"; }
  if [ "$add" = 0 ]; then printf '%s\n' "$entry"; return 0; fi

  info="$(printf '%s' "$entry" | bibjq 'entry_info | [(.key | gsub("\\s+"; " ")), (.doi // "")] | join("\t")')" || { CODE=3 die "cannot read the fixed entry"; }
  base="${info%%$'\t'*}"; doi="${info#*$'\t'}"
  kf="$TMP/keys.tsv"; : > "$kf"
  if [ -f "$BIB_PATH" ]; then
    bibjq 'entries[] | entry_info | [(.key | gsub("\\s+"; " ")), (.doi // "")] | join("\t")' < "$BIB_PATH" > "$kf" || { CODE=3 die "cannot read $BIB_PATH"; }
    if [ -n "$doi" ]; then
      key="$(awk -F'\t' -v d="$doi" '$2 == d { print $1; exit }' "$kf")"
      if [ -n "$key" ]; then echo "note: already in $BIB_PATH as $key" >&2; printf '%s\n' "$key"; return 0; fi
    fi
  fi
  key="$base"; n=0
  while awk -F'\t' -v k="$key" 'tolower($1) == tolower(k) { f = 1 } END { exit !f }' "$kf"; do
    n=$((n + 1))
    [ "$n" -le 25 ] || { CODE=3 die "no free key for $base in $BIB_PATH"; }
    # shellcheck disable=SC2059
    letter="$(printf "\\$(printf '%03o' $((97 + n)))")"
    key="$base$letter"
  done
  if [ "$key" != "$base" ]; then
    entry="$(printf '%s' "$entry" | bibjq 'rekey($k)' --arg k "$key")" || { CODE=3 die "cannot rekey the entry"; }
  fi
  mkdir -p "$(dirname "$BIB_PATH")" 2>/dev/null || { CODE=3 die "cannot create the directory of $BIB_PATH"; }
  {
    if [ -s "$BIB_PATH" ]; then
      [ -z "$(tail -c 1 "$BIB_PATH")" ] || printf '\n'
      printf '\n'
    fi
    printf '%s\n' "$entry"
  } >> "$BIB_PATH" || { CODE=3 die "cannot write $BIB_PATH"; }
  echo "note: added $key to $BIB_PATH" >&2
  printf '%s\n' "$key"
}

# verify filter: input none; --slurpfile cr (Crossref body or nothing), --arg src crossref|arxiv, bt/ba/by (bib), mt/ma/my (arXiv meta).
# Prints "status<TAB>detail".
VERIFY_JQ='
include "scholar-norm";
def clean: gsub("<[^>]+>"; " ") | gsub("[{}]"; "") | gsub("\\s+"; " ") | gsub("^ | $"; "");
def rank: {ok: 0, warn: 1, fail: 2, retracted: 3};
($cr[0].message // null) as $m
| (if $src == "crossref"
   then {t: ($m.title[0] // ""), a: ($m.author[0].family // $m.author[0].name // ""), y: ($m.issued["date-parts"][0][0] // "" | tostring)}
   else {t: $mt, a: $ma, y: $my} end) as $meta
| ($meta.t | clean) as $mtc
| ($bt | norm) as $nb | ($meta.t | norm) as $nm
| ($ba | [splits("\\s+and\\s+"; "i")][0] // "") as $ba1
| ($meta.a | clean) as $mac
| ($by | gsub("[^0-9]"; "")) as $by1 | ($meta.y | gsub("[^0-9]"; "")) as $my1
| [
    (if $nb == "" or $nm == "" then (if ($bt | clean) == $mtc then empty else {s: "fail", m: "title mismatch: \"\($mtc)\""} end)
     elif $nb == $nm then empty
     elif ($nb | startswith($nm)) or ($nm | startswith($nb)) then {s: "warn", m: "title differs (subtitle?)"}
     else {s: "fail", m: "title mismatch: \"\($mtc)\""} end),
    (if ($ba1 | clean) == "" or $mac == "" then {s: "warn", m: "first author unknown"}
     elif ($ba1 | lastname) == "" or ($meta.a | lastname) == "" then (if ($ba1 | clean) == $mac then empty else {s: "fail", m: "first author mismatch: \($mac)"} end)
     elif ($ba1 | lastname) == ($meta.a | lastname) then empty
     else {s: "fail", m: "first author mismatch: \($mac)"} end),
    (if $by1 == "" or $my1 == "" then {s: "warn", m: "year unknown"}
     elif $by1 == $my1 then empty
     else {s: "fail", m: "year mismatch: \($my1)"} end),
    (if $src == "crossref" then
       (($m["updated-by"] // [])[]? | select(type == "object")
        | if .type == "retraction" or .type == "withdrawal" then {s: "retracted", m: "retracted (\(.DOI))"}
          elif .type == "expression_of_concern" then {s: "warn", m: "expression of concern (\(.DOI))"}
          elif .type == "correction" or .type == "erratum" then {s: "ok", m: "correction (\(.DOI))"}
          else empty end),
       (if (($m["update-to"] // []) | length) > 0 then {s: "fail", m: "this DOI is a notice, not the paper"} else empty end),
       (if (($m.title[0] // "") | norm | startswith("retracted ")) then {s: "retracted", m: "title says RETRACTED"} else empty end)
     else empty end)
  ] as $r
| ($r | reduce .[] as $x ([]; if any(.[]; .m == $x.m) then . else . + [$x] end)) as $u
| (($u | map(rank[.s]) | max) // 0) as $w
| (["ok", "warn", "fail", "retracted"][$w]) + "\t" + (if ($u | length) == 0 then "-" else ($u | map(.m) | join("; ")) end)
'

cmd_verify() {
  local bib="" have_bib=0 k d ep ap t au y src aid code line st dt n_bad=0 n_err=0 n_good=0 n_cr=0 cf delay mt ma my cr="$TMP/cr.json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --bib)
        [ "$have_bib" = 0 ] || die "option --bib given twice"
        [ $# -ge 2 ] && [ -n "$2" ] || die "option --bib needs a value"
        bib="$2"; have_bib=1; shift 2;;
      -*) die "unknown option '$1'";;
      *) die "verify takes no argument (got '$1')";;
    esac
  done
  if [ "$have_bib" = 1 ]; then BIB_PATH="$bib"; else default_bib; fi
  [ ! -e "$BIB_PATH" ] || [ -f "$BIB_PATH" ] || die "$BIB_PATH is not a regular file"
  [ -f "$BIB_PATH" ] || die "$BIB_PATH not found"
  delay="${SCHOLAR_CROSSREF_DELAY:-0.2}"
  case "$delay" in ''|*[!0-9.]*) delay=0.2;; esac
  : > "$TMP/empty"
  bibjq 'entries[] | entry_info
    | [.key, .doi, .eprint, .archiveprefix, .title, .author, .year] | map("x" + ((. // "") | gsub("\\s+"; " "))) | join("\t")' < "$BIB_PATH" > "$TMP/entries.tsv" \
    || { CODE=3 die "cannot read $BIB_PATH"; }
  printf 'key\tstatus\tdetail\n'
  while IFS=$'\t' read -r k d ep ap t au y <&3; do
    k="${k#x}"; d="${d#x}"; ep="${ep#x}"; ap="${ap#x}"; t="${t#x}"; au="${au#x}"; y="${y#x}"
    src=""; aid=""; st=""; dt="-"
    if [ -n "$d" ]; then
      if [[ "$d" =~ ^10\.48550/arxiv\.(.+)$ ]]; then src=arxiv; aid="${BASH_REMATCH[1]}"; else src=crossref; fi
    elif [ -n "$ep" ] && [ "$(printf '%s' "$ap" | tr 'A-Z' 'a-z')" = arxiv ]; then
      src=arxiv; aid="$ep"
    fi
    if [ "$src" = arxiv ]; then
      aid="$(printf '%s' "$aid" | tr -d ' ' | sed -e 's/^[Aa][Rr][Xx][Ii][Vv]://' -e 's/v[0-9][0-9]*$//')"
      [[ "$aid" =~ ^[A-Za-z0-9./-]+$ ]] || { st=error; dt="unusable arXiv id"; }
    fi
    if [ -z "$src" ]; then
      st=nodoi; dt="no doi or arXiv eprint"
    elif [ -z "$st" ] && [ "$src" = crossref ]; then
      [ "$n_cr" -eq 0 ] || sleep "$delay"
      n_cr=$((n_cr + 1))
      code="$(http_get "https://api.crossref.org/works/$(enc_doi "$d")" "$cr")"
      case "$code" in
        200) ;;
        404) st=notfound; dt="not in Crossref";;
        *) st=error; dt="Crossref HTTP $code";;
      esac
    elif [ -z "$st" ]; then
      code="$(arxiv_get "https://export.arxiv.org/api/query?id_list=$aid" "$TMP/ax.xml")"
      if [ "$code" != 200 ]; then st=error; dt="arXiv HTTP $code"
      else
        awk -f "$AXAWK" "$TMP/ax.xml" > "$TMP/ax.tsv" 2> "$TMP/ax.err"
        if [ -s "$TMP/ax.err" ]; then st=error; dt="arXiv returned an error: $(ax_error)"
        elif [ ! -s "$TMP/ax.tsv" ]; then st=notfound; dt="not in arXiv"
        else
          mt="$(awk -F'\t' 'NR == 1 { print $3 }' "$TMP/ax.tsv")"
          ma="$(awk -F'\t' 'NR == 1 { p = index($10, "; "); print (p > 0 ? substr($10, 1, p - 1) : $10) }' "$TMP/ax.tsv")"
          my="$(awk -F'\t' 'NR == 1 { print substr($4, 1, 4) }' "$TMP/ax.tsv")"
        fi
      fi
    fi
    if [ -z "$st" ]; then
      if [ "$src" = crossref ]; then cf="$cr"; else cf="$TMP/empty"; fi
      if line="$(jq -nr -L "$HERE" --slurpfile cr "$cf" --arg src "$src" --arg bt "$t" --arg ba "$au" --arg by "$y" \
          --arg mt "${mt:-}" --arg ma "${ma:-}" --arg my "${my:-}" "$VERIFY_JQ" 2>/dev/null)"; then
        st="${line%%$'\t'*}"; dt="${line#*$'\t'}"
      else
        st=error; dt="unreadable $([ "$src" = crossref ] && echo Crossref || echo arXiv) response"
      fi
    fi
    case "$st" in ok|warn) n_good=$((n_good + 1));; error) n_err=$((n_err + 1));; *) n_bad=$((n_bad + 1));; esac
    printf '%s\t%s\t%s\n' "$(printf '%s' "$k" | tr '\t' ' ')" "$st" "$dt"
    mt=""; ma=""; my=""
  done 3< "$TMP/entries.tsv"
  if [ "$n_bad" -gt 0 ]; then return 4; fi
  if [ "$n_err" -gt 0 ] && [ "$n_good" -eq 0 ]; then return 3; fi
  return 0
}

# lit_paths [--bib <path>] args: sets TOP, LIT, MANIFEST, BIB_PATH and POS (the positional arguments) for pdf and pdfs
lit_paths() {
  local have_bib=0 bib=""
  POS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --bib)
        [ "$have_bib" = 0 ] || die "option --bib given twice"
        [ $# -ge 2 ] && [ -n "$2" ] || die "option --bib needs a value"
        bib="$2"; have_bib=1; shift 2;;
      -*) die "unknown option '$1'";;
      *) POS+=("$1"); shift;;
    esac
  done
  TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
  [ -n "$TOP" ] || die "not in a git repository"
  if [ "$have_bib" = 1 ]; then BIB_PATH="$bib"; else BIB_PATH="$TOP/article/refs.bib"; fi
  [ ! -e "$BIB_PATH" ] || [ -f "$BIB_PATH" ] || die "$BIB_PATH is not a regular file"
  LIT="$TOP/article/literature"
  MANIFEST="$LIT/manifest.tsv"
}

# valid_pdf <file>: more than 1024 bytes and starts with %PDF-
valid_pdf() {
  [ -f "$1" ] || return 1
  [ "$(wc -c < "$1" | tr -d ' ')" -gt 1024 ] && [ "$(head -c 5 "$1")" = "%PDF-" ]
}

MANIFEST_HEADER=$'key\tid\ttitle\tpdf\tsource'

# manifest_check: dies when an existing manifest does not start with the header
manifest_check() {
  [ ! -f "$MANIFEST" ] || [ "$(head -n 1 "$MANIFEST" | tr -d '\r')" = "$MANIFEST_HEADER" ] || die "$MANIFEST does not start with the header (key, id, title, pdf, source)"
}

# manifest_set <key> <id> <title> <pdf> <source>: appends the row or replaces the row of that key in place (temp file + mv)
manifest_set() {
  local new="$TMP/manifest.new" src="$MANIFEST"
  mkdir -p "$LIT" 2>/dev/null || die "cannot create $LIT"
  [ -f "$src" ] || src=/dev/null
  M_KEY="$1" M_ID="$2" M_TITLE="$3" M_PDF="$4" M_SRC="$5" awk -F'\t' -v OFS='\t' '
    BEGIN { print "key", "id", "title", "pdf", "source"
            k = ENVIRON["M_KEY"]; row = k OFS ENVIRON["M_ID"] OFS ENVIRON["M_TITLE"] OFS ENVIRON["M_PDF"] OFS ENVIRON["M_SRC"] }
    NR == 1 || $0 == "" { next }
    $1 == k { if (!done) { print row; done = 1 }; next }
    { print }
    END { if (!done) print row }' "$src" > "$new" && mv "$new" "$MANIFEST" || die "cannot write $MANIFEST"
}

# write_missing: regenerates missing.md from the manifest
write_missing() {
  local new="$TMP/missing.new"
  awk -F'\t' '
    NR == 1 || $0 == "" { next }
    $4 == "missing" {
      t = $3; gsub(/\|/, "\\|", t)
      l = $2; if (l ~ /^doi:/) l = "https://doi.org/" substr(l, 5); else if (l ~ /^arxiv:/) l = "https://arxiv.org/abs/" substr(l, 7)
      rows = rows "| " $1 ".pdf | " t " | " l " |\n"; n++ }
    END {
      print "# PDFs to download by hand\n"
      if (n == 0) { print "None: every paper in the manifest has its PDF."; exit }
      print "Save each PDF in article/literature/pdfs/ with exactly the file name shown, then run: scholar.sh pdfs\n"
      print "| File name | Title | Link |\n|---|---|---|"
      printf "%s", rows }' "$MANIFEST" > "$new" && mv "$new" "$LIT/missing.md" || die "cannot write $LIT/missing.md"
}

# fetch_pdf <url>: downloads into $TMP/dl.pdf; returns 0 for a valid PDF, else notes the reason on stderr
fetch_pdf() {
  local url="$1" code lc
  lc="$(printf '%s' "$url" | tr 'A-Z' 'a-z')"
  if [[ "$lc" =~ ^https?://([a-z0-9-]+\.)*arxiv\.org([/:?#]|$) ]]; then
    code="$(FOLLOW=1 PLAIN_UA=1 arxiv_get "$url" "$TMP/dl.pdf" --max-time 60 --max-redirs 10 --max-filesize 50000000)"
  else
    code="$(FOLLOW=1 PLAIN_UA=1 http_get "$url" "$TMP/dl.pdf" --max-time 60 --max-redirs 10 --max-filesize 50000000)"
  fi
  if [ "$code" != 200 ]; then echo "tried $url: HTTP $code" >&2; return 1; fi
  if ! valid_pdf "$TMP/dl.pdf"; then echo "tried $url: not a PDF" >&2; return 1; fi
}

# try_url <url>: fetch_pdf unless the URL was already tried; sets GOT on success
try_url() {
  case "$TRIED" in *$'\n'"$1"$'\n'*) return 1;; esac
  TRIED="$TRIED$1"$'\n'
  fetch_pdf "$1" && { GOT="$1"; return 0; }
  return 1
}

cmd_pdf() {
  lit_paths "$@"
  [ "${#POS[@]}" -eq 1 ] || die "pdf needs exactly one identifier"
  local ident="${POS[0]}" kind val id key title info code cf cu email row rpdf rsrc rel pdfdir
  parse_id "$ident" || die "unrecognized identifier '$ident' (use doi:<doi> or arxiv:<id>)"
  [ "$ID_KIND" != openalex ] || die "pdf needs a DOI or an arXiv id"
  kind="$ID_KIND"; val="$ID_VAL"; id="$kind:$val"
  [ -f "$BIB_PATH" ] || die "$BIB_PATH not found"
  info="$(bibjq 'entries[] | entry_info
    | select(if $kind == "doi" then .doi == $v
        else ((.doi // "") | sub("v[0-9]+$"; "")) == ("10.48550/arxiv." + $v)
          or (((.archiveprefix // "") | ascii_downcase | gsub("\\s+"; "")) == "arxiv"
              and ((.eprint // "") | gsub("\\s+"; "") | sub("^(?i:arxiv:)"; "") | sub("v[0-9]+$"; "")) == $v) end)
    | [(.key | gsub("\\s+"; " ")), ((.title // "") | gsub("[{}]"; "") | gsub("\\s+"; " ") | gsub("^ | $"; ""))] | join("\t")' --arg kind "$kind" --arg v "$val" < "$BIB_PATH" | head -n 1)" \
    || { CODE=3 die "cannot read $BIB_PATH"; }
  if [ -z "$info" ]; then die "$ident is not in $BIB_PATH; add it first: scholar.sh bibtex $ident --add"; fi
  key="${info%%$'\t'*}"; title="${info#*$'\t'}"
  [ -n "$title" ] || title="-"
  [[ "$key" =~ $KEY_RE ]] || die "the key '$key' cannot be used as a file name"
  manifest_check
  pdfdir="$LIT/pdfs"; rel="article/literature/pdfs/$key.pdf"
  rpdf=""; rsrc="-"
  if [ -f "$MANIFEST" ]; then
    row="$(awk -F'\t' -v k="$key" 'NR > 1 && $1 == k { print "x" $4 "\tx" $5; exit }' "$MANIFEST")"
    if [ -n "$row" ]; then rpdf="${row%%$'\t'*}"; rpdf="${rpdf#x}"; rsrc="${row#*$'\t'}"; rsrc="${rsrc#x}"; fi
  fi
  if valid_pdf "$pdfdir/$key.pdf"; then
    if [ "$rpdf" = oa ]; then manifest_set "$key" "$id" "$title" oa "$rsrc"; else manifest_set "$key" "$id" "$title" manual "-"; fi
    write_missing
    echo "present $key $rel"
    return 0
  fi

  TRIED=$'\n'; GOT=""
  if [ "$kind" = arxiv ]; then
    try_url "https://arxiv.org/pdf/$val" || true
  else
    email="${SCHOLAR_EMAIL:-}"
    if [ -z "$email" ]; then
      echo "note: Unpaywall skipped: set SCHOLAR_EMAIL to use it" >&2
    else
      cu="$TMP/unpaywall.json"
      code="$(http_get "https://api.unpaywall.org/v2/$(enc_doi "$val")?email=$(jq -rn --arg e "$email" '$e | @uri')" "$cu")"
      if [ "$code" = 200 ] && jq -r '
          [(.oa_locations // [])[]? | select((.url_for_pdf | type) == "string" and (.url_for_pdf | test("^https?://")))] as $l
          | ([$l[] | select(.host_type == "publisher")] + [$l[] | select(.host_type != "publisher")])
          | reduce .[].url_for_pdf as $u ([]; if index([$u]) then . else . + [$u] end) | .[]' "$cu" > "$TMP/cands" 2>/dev/null; then
        while IFS= read -r cf; do
          try_url "$cf" && break
        done < "$TMP/cands"
      else
        [ "$code" = 200 ] && code="unreadable body"
        echo "note: Unpaywall HTTP $code" >&2
      fi
    fi
    if [ -z "$GOT" ]; then
      cu="$TMP/openalex.json"
      code="$(api_get openalex "https://api.openalex.org/works/doi:$(enc_doi "$val")?select=open_access" "$cu")"
      if [ "$code" = 200 ]; then
        cf="$(jq -r '.open_access.oa_url | select(type == "string" and test("^https?://"))' "$cu" 2>/dev/null | head -n 1)"
        [ -z "$cf" ] || try_url "$cf" || true
      else
        echo "note: OpenAlex HTTP $code" >&2
      fi
    fi
  fi

  if [ -n "$GOT" ]; then
    mkdir -p "$pdfdir" 2>/dev/null && mv "$TMP/dl.pdf" "$pdfdir/$key.pdf" || die "cannot write $pdfdir/$key.pdf"
    manifest_set "$key" "$id" "$title" oa "$GOT"
    write_missing
    echo "downloaded $key $rel"
    return 0
  fi
  manifest_set "$key" "$id" "$title" missing "-"
  write_missing
  echo "missing $key (listed in article/literature/missing.md)"
  return 2
}

cmd_pdfs() {
  lit_paths "$@"
  [ "${#POS[@]}" -eq 0 ] || die "pdfs takes no argument (got '${POS[0]}')"
  [ -f "$MANIFEST" ] || die "no manifest yet (article/literature/manifest.tsv); run scholar.sh pdf <id> first"
  manifest_check
  local k i t p s note new="$TMP/manifest.new" out="$TMP/pdfs.out"
  awk -F'\t' -v OFS='\t' 'NR > 1 && $0 != "" { print "x" $1, "x" $2, "x" $3, "x" $4, "x" $5 }' "$MANIFEST" > "$TMP/rows.tsv"
  printf '%s\n' "$MANIFEST_HEADER" > "$new"
  printf 'key\tpdf\tnote\n' > "$out"
  while IFS=$'\t' read -r k i t p s <&3; do
    k="${k#x}"; i="${i#x}"; t="${t#x}"; p="${p#x}"; s="${s#x}"; note="-"
    if ! [[ "$k" =~ $KEY_RE ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$i" "$t" "$p" "$s" >> "$new"
      printf '%s\t%s\t%s\n' "$k" "$p" "invalid key" >> "$out"
      continue
    fi
    if valid_pdf "$LIT/pdfs/$k.pdf"; then
      if [ "$p" = missing ]; then p=manual; s="-"; fi
    elif [ -e "$LIT/pdfs/$k.pdf" ]; then
      p=missing; s="-"; note="not a valid PDF"
    else
      p=missing; s="-"; note="file gone"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$i" "$t" "$p" "$s" >> "$new"
    printf '%s\t%s\t%s\n' "$k" "$p" "$note" >> "$out"
  done 3< "$TMP/rows.tsv"
  mv "$new" "$MANIFEST" || die "cannot write $MANIFEST"
  write_missing
  cat "$out"
}

cmd="$1"; shift
case "$cmd" in
  search) cmd_search "$@"; exit $?;;
  show) cmd_show "$@"; exit $?;;
  bibtex) cmd_bibtex "$@"; exit $?;;
  verify) cmd_verify "$@"; exit $?;;
  pdf) cmd_pdf "$@"; exit $?;;
  pdfs) cmd_pdfs "$@"; exit $?;;
  *) die "unknown command '$cmd' (use search, show, bibtex, verify, pdf or pdfs; -h for help)";;
esac
