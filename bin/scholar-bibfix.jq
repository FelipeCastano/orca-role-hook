include "scholar-norm";
# Input: raw BibTeX string of ONE entry (jq -Rs). Output: fixed entry.
# field($name): value inside the outermost braces of `name = {...}` (case-insensitive name), or null.
def field_span($name):
  . as $s
  | ([match("(^|[,\\s])" + $name + "\\s*=\\s*\\{"; "gi")] | first) as $m
  | if $m == null then null else
      ($m.offset + $m.length) as $start
      | ($s[$start:] | explode) as $cs
      | (reduce range(0; $cs|length) as $i ({d:1, end:null};
           if .end != null then . elif $cs[$i] == 123 then .d += 1
           elif $cs[$i] == 125 then (.d -= 1 | if .d == 0 then .end = $i else . end) else . end)).end as $e
      | if $e == null then null else {start: $start, end: ($start + $e)} end
    end;
def field($name): field_span($name) as $p | if $p == null then null else .[$p.start:$p.end] end;
# true iff the whole string is one {...} group (the brace at 0 closes at the last char)
def wrapped:
  explode as $cs
  | ($cs|length) > 1 and $cs[0] == 123 and
    (reduce range(0; $cs|length) as $i ({d:0, close:null};
       if .close != null then . elif $cs[$i] == 123 then .d += 1
       elif $cs[$i] == 125 then (.d -= 1 | if .d == 0 then .close = $i else . end) else . end)).close == (($cs|length) - 1);
def protect_title:
  field_span("title") as $p
  | if $p == null then . else
      .[$p.start:$p.end] as $t
      | if ($t | wrapped) then . else .[:$p.start] + "{" + $t + "}" + .[$p.end:] end
    end;
def rekey($k): sub("^\\s*@(?<t>[A-Za-z]+)\\s*\\{[^,]*,"; "@\(.t){\($k),");
def fix_month:
  {"jan":"jan","feb":"feb","mar":"mar","apr":"apr","may":"may","jun":"jun","jul":"jul","aug":"aug","sep":"sep","oct":"oct","nov":"nov","dec":"dec"} as $mm
  | gsub("month\\s*=\\s*(?<m>[A-Za-z]+)"; "month = " + ($mm[(.m|ascii_downcase|.[0:3])] // ("{" + .m + "}")));
def fix_pages: (field_span("pages")) as $p | if $p == null then . else .[:$p.start] + (.[$p.start:$p.end] | gsub("–|—|-+"; "--")) + .[$p.end:] end;
def stop: ["a","an","the","on","of","for","in","and","to","with","from","towards","toward","via","is","are"];
def makekey:
  (field("author") // "" | (split(" and ")[0] // "") | lastname | gsub(" ";"")) as $a
  | (field("year") // "" | gsub("[^0-9]";"")) as $y
  | (field("title") // "" | norm | split(" ") | map(select(. as $w | stop | index($w) | not)) | first // "") as $w
  | $a + $y + $w;
def fixentry: sub("^\\s+"; "") | sub("\\s+$"; "") | . as $raw | makekey as $k | rekey($k) | protect_title | fix_month | fix_pages;
# Input: raw text of a whole .bib file. Output: array of the raw entry strings (string, comment and preamble blocks excluded).
def entries:
  [splits("\n(?=[ \t]*@)")] | map(select(test("^\\s*@")) | select(test("^\\s*@\\s*(string|comment|preamble)\\b"; "i") | not));
# Input: one raw entry. Output: its citation key.
def entry_key: sub("^\\s*@[A-Za-z]+\\s*\\{"; "") | split(",")[0] | gsub("^\\s+|\\s+$"; "");
# Value of `name = {...}`, `name = "..."` or `name = bare`, or null.
def fieldv($name):
  field($name)
  // (capture("(^|[,\\s])" + $name + "\\s*=\\s*\"(?<v>[^\"]*)\""; "i") | .v)
  // (capture("(^|[,\\s])" + $name + "\\s*=\\s*(?<v>[A-Za-z0-9_:.\\-]+)\\s*[,}]"; "i") | .v)
  // null;
# Input: one raw entry. Output: {key, doi, eprint, archiveprefix, title, author, year} (null when missing).
def entry_info:
  {key: entry_key, doi: (fieldv("doi") | if . == null then null else gsub("^\\s+|\\s+$"; "") | sub("^https?://(dx\\.)?doi\\.org/"; "") | ascii_downcase end),
   eprint: fieldv("eprint"), archiveprefix: fieldv("archiveprefix"), title: fieldv("title"), author: fieldv("author"), year: fieldv("year")};
