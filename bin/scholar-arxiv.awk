# POSIX awk: arXiv Atom feed -> TSV: id version title published updated doi journal_ref primary_cat pdf authors(;) abstract
function tag(s, t,   a, b, r) {
  a = index(s, "<" t ">"); if (a == 0) { a = index(s, "<" t " "); if (a == 0) return "" ; r = substr(s, a); a = a + index(r, ">") } else a = a + length(t) + 2
  r = substr(s, a); b = index(r, "</" t ">"); if (b == 0) return ""
  return clean(substr(r, 1, b - 1))
}
function clean(x) { gsub(/[ \t\r\n]+/, " ", x); sub(/^ /, "", x); sub(/ $/, "", x)
  gsub(/&lt;/, "<", x); gsub(/&gt;/, ">", x); gsub(/&quot;/, "\"", x); gsub(/&#39;|&apos;/, "'", x); gsub(/&amp;/, "\\&", x); return x }
function attr(s, pre, name,   a, r, b) { a = index(s, pre); if (a == 0) return ""; r = substr(s, a)
  a = index(r, name "=\""); if (a == 0) return ""; r = substr(r, a + length(name) + 2); b = index(r, "\""); return substr(r, 1, b - 1) }
{ doc = doc " " $0 }
END {
  n = split(doc, E, "<entry>")
  for (i = 2; i <= n; i++) {
    e = E[i]; id = tag(e, "id")
    if (id ~ /api\/errors/) { print "ERROR\t" tag(e, "summary") > "/dev/stderr"; continue }
    ver = id; sub(/^.*v/, "v", ver); if (ver !~ /^v[0-9]+$/) ver = ""
    sid = id; sub(/^https?:\/\/arxiv\.org\/abs\//, "", sid); sub(/v[0-9]+$/, "", sid)
    au = ""; r = e
    while ((p = index(r, "<author>")) > 0) { r = substr(r, p + 8); nm = tag(r, "name"); au = (au == "" ? nm : au "; " nm) }
    pdf = "https://arxiv.org/pdf/" sid ver
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sid, ver, tag(e, "title"), tag(e, "published"), tag(e, "updated"), tag(e, "arxiv:doi"), tag(e, "arxiv:journal_ref"), attr(e, "<arxiv:primary_category", "term"), pdf, au, tag(e, "summary")
  }
}
