#!/usr/bin/env python3
"""Usage metrics of the kit's Claude Code sessions, read from the transcripts. Run through usage-metrics.sh (python3 >= 3.9, stdlib only, -I).

  usage_metrics.py --once
  usage_metrics.py --report [--task <t>] [--since <YYYY-MM-DD>] [--json]

One pass reads ONLY <claude projects>/*/*.jsonl (and <session>/subagents/*.jsonl) and $KIT/metrics/*; it runs no other program. The transcripts root is
$ORCA_ROLES_CLAUDE_PROJECTS, else ${CLAUDE_CONFIG_DIR:-~/.claude}/projects. The store never holds prompts, tool inputs or tool outputs: only counts,
tool names, durations, verdict words and line counts.

Store: $KIT/metrics/state.json (offsets and running totals, rewritten every pass) and $KIT/metrics/sessions-YYYY-MM-DD.jsonl (UTC day of the pass):
one JSON line per kit session that changed in that pass, with all its cumulative values:
  ts                 pass time (ISO-8601 UTC)
  session_id, task, project, orca_roles_role   labels (task/project: the longest worktrees.jsonl path that holds the session's first cwd, "" if none;
                     role: from the kit's role message, "" if none), effort (the last api-request's output_config.effort, default "medium"),
                     query_source ("main"), service_version
  first, last        timestamps of the session's first and last line
  models             {model: {input, output, cacheRead, cacheCreation, cacheWrite5m, cacheWrite1h, thinking, turns,
                              cost, costByType {input, output, cacheRead, cacheWrite, webSearch}, cacheSavings}}
  tokens             the same token counts summed over the models (input, output, cacheRead, cacheCreation, thinking)
  cost               max(costPriced, costState)   (USD; never decreases)
  costPriced         the tokens priced with bin/usage_prices.json (models without a price count 0 and are listed in unpriced)
  costState          totalCostUSD of the last cost-state line, null if none
  costByType, cacheSavings   summed over the models (cacheSavings: the cache tokens priced as uncached input, minus what they cost)
  tools              {tool name: {calls, errors, seconds}}   (seconds: tool_use to tool_result)
  turns, userMessages, compactions, maxContext, apiErrors, modelChanges
  lines              {added, removed, source}   source "cost-state" or "edits" (counted from Edit/Write/MultiEdit)
  workerDone         [{verdict, seconds}]   one per worker_done send; verdict ACCEPTED/REJECTED from --subject, then a literal --body, else "";
                     seconds from the session's prompt that names the task to the send (null if none)
  commits            {count, insertions, deletions}   Bash `git commit` calls that succeeded
  unpriced           models with no price

Rotation: on the first pass of a UTC day, sessions-*.jsonl older than settings.metrics.retentionDays are deleted (never state.json,
worktrees.jsonl or events.jsonl). Errors go to $KIT/metrics/usage-metrics.log (the last 1000 lines kept).
"""
import calendar
import datetime
import json
import os
import re
import shlex
import sys
import time

LIMIT = float(os.environ.get("ORCA_ROLES_METRICS_LIMIT", "60"))
KIT = os.environ.get("KIT") or os.path.join(os.path.expanduser("~"), ".orca-roles")
MDIR = os.path.join(KIT, "metrics")
LOG_KEEP = 1000
RECENT_IDS = 300
TYPES = ("input", "output", "cacheRead", "cacheWrite")
ROLE_RE = re.compile(r"Read (.*?) and adopt that role", re.S)
MD_RE = re.compile(r"[^/\s]+\.md")
TASK_RE = re.compile(r"task_[0-9a-f]{8,}")
VERDICT_RE = re.compile(r"\b(ACCEPTED|REJECTED)\b")
INS_RE = re.compile(r"(\d+) insertions?\(\+\)")
DEL_RE = re.compile(r"(\d+) deletions?\(-\)")
TS_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    try:
        os.makedirs(MDIR, exist_ok=True)
        with open(os.path.join(MDIR, "usage-metrics.log"), "a") as f:
            f.write("%s %s\n" % (now_iso(), " ".join(str(msg).split())))
    except OSError:
        pass


def trim_log():
    p = os.path.join(MDIR, "usage-metrics.log")
    try:
        with open(p) as f:
            lines = f.readlines()
        if len(lines) > LOG_KEEP:
            tmp = p + ".tmp"
            with open(tmp, "w") as f:
                f.writelines(lines[-LOG_KEEP:])
            os.replace(tmp, p)
    except OSError:
        pass


def parse_ts(s):
    m = TS_RE.match(s) if isinstance(s, str) else None
    if not m:
        return None
    y, mo, d, h, mi, se = (int(x) for x in m.groups()[:6])
    return calendar.timegm((y, mo, d, h, mi, se, 0, 0, 0)) + (float("0." + m.group(7)) if m.group(7) else 0.0)


def global_config():
    for name in ("config.json", "config.default.json"):
        try:
            with open(os.path.join(KIT, name)) as f:
                c = json.load(f)
            if isinstance(c, dict):
                return c
        except (OSError, ValueError):
            continue
    return {}


def metrics_settings():
    s = (global_config().get("settings") or {})
    m = s.get("metrics") if isinstance(s, dict) else None
    return m if isinstance(m, dict) else {}


def retention_days():
    v = metrics_settings().get("retentionDays", 90)
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 1 else 90


# ---------------------------------------------------------------- prices
_PRICES = None


def prices():
    global _PRICES
    if _PRICES is None:
        try:
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage_prices.json")) as f:
                _PRICES = json.load(f).get("models") or {}
        except (OSError, ValueError):
            _PRICES = {}
    return _PRICES


def price_of(model):
    if not isinstance(model, str):
        return None
    model = model.split("[")[0]
    best = None
    for mid, p in prices().items():
        if model == mid or model.startswith(mid):
            if best is None or len(mid) > len(best[0]):
                best = (mid, p)
    return best[1] if best else None


def cost_of(model, u):
    """-> {input, output, cacheRead, cacheWrite, webSearch, saved} in USD for one response, or None without a price."""
    p = price_of(model)
    if p is None:
        return None
    inp, out = u.get("input_tokens") or 0, u.get("output_tokens") or 0
    cr, cw = u.get("cache_read_input_tokens") or 0, u.get("cache_creation_input_tokens") or 0
    h = min(((u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens") or 0), cw)
    lp = p.get("longPrompt")
    if lp and inp + cr + cw > lp.get("abovePromptTokens", 0):
        p = lp if "webSearch" in lp else dict(lp, webSearch=p.get("webSearch", 0))
    mult = 1.1 if u.get("inference_geo") == "us" else 1.0
    c = {
        "input": inp * p["input"] / 1e6,
        "output": out * p["output"] / 1e6,
        "cacheRead": cr * p["cacheRead"] / 1e6,
        "cacheWrite": ((cw - h) * p["cacheWrite5m"] + h * p["cacheWrite1h"]) / 1e6,
        "webSearch": ((u.get("server_tool_use") or {}).get("web_search_requests") or 0) * p.get("webSearch", 0.01),
    }
    c = {k: v * mult for k, v in c.items()}
    c["saved"] = (cr + cw) * p["input"] / 1e6 * mult - c["cacheRead"] - c["cacheWrite"]
    return c


# ---------------------------------------------------------------- session state
def new_session(sid):
    return {
        "sid": sid, "kit": None, "cwd": "", "role": "", "prompts": 0, "first": "", "last": "", "version": "", "effort": "medium",
        "models": {}, "tools": {}, "turns": 0, "userMessages": 0, "compactions": 0, "maxContext": 0, "apiErrors": 0, "modelChanges": 0,
        "lastModel": "", "locEdits": [0, 0], "cs": None, "workerDone": [], "commits": [0, 0, 0], "taskPrompts": {}, "pending": {},
        "special": {}, "recent": [], "unpriced": [],
    }


def model_row(S, model):
    r = S["models"].get(model)
    if r is None:
        r = S["models"][model] = {"input": 0, "output": 0, "cacheRead": 0, "cacheCreation": 0, "cacheWrite5m": 0, "cacheWrite1h": 0,
                                  "thinking": 0, "turns": 0, "cost": 0.0, "costByType": {k: 0.0 for k in TYPES + ("webSearch",)},
                                  "cacheSavings": 0.0}
    return r


def text_of(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
    return ""


def role_in(text):
    m = ROLE_RE.search(text)
    if not m:
        return ""
    names = [x[:-3] for x in MD_RE.findall(m.group(1)) if not x.startswith("common-")]
    return names[-1] if names else ""


def count_lines(s):
    return 0 if not isinstance(s, str) or not s else s.count("\n") + (0 if s.endswith("\n") else 1)


def simple_commands(cmd):
    """-> the simple commands of a shell command line as token lists (split at ; & | ( ) and newlines outside quotes), or None when it cannot be tokenised."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    out, cur = [], []
    try:
        for t in lex:
            if t and all(c in ";&|()\n" for c in t):
                if cur:
                    out.append(cur)
                cur = []
            else:
                cur.append(t)
    except ValueError:
        return None
    if cur:
        out.append(cur)
    return out


def command_words(toks):
    """The command's words without leading VAR=value assignments."""
    i = 0
    while i < len(toks) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[i]):
        i += 1
    return toks[i:]


def is_orca_send(w):
    return len(w) >= 3 and os.path.basename(w[0]) == "orca" and w[1] == "orchestration" and w[2] == "send"


def is_git_commit(w):
    if not w or os.path.basename(w[0]) != "git":
        return False
    i = 1
    while i < len(w):
        if w[i] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
            i += 2
        elif w[i].startswith("-"):
            i += 1
        else:
            return w[i] == "commit"
    return False


def git_commit_in(cmd):
    cs = simple_commands(cmd)
    if cs is None:
        return re.search(r"(?:^|[;&|(\n])\s*git(?:\s+-C\s+\S+|\s+-c\s+\S+)*\s+commit(?![\w-])", cmd) is not None
    return any(is_git_commit(command_words(c)) for c in cs)


def worker_done_of(cmd):
    """-> (verdict, task id) of a Bash `orca orchestration send ... --type worker_done` command, or None."""
    if "worker_done" not in cmd or "orchestration" not in cmd:
        return None
    subj = body = task = None
    cs = simple_commands(cmd)
    if cs is not None:
        for c in cs:
            t = command_words(c)
            if not is_orca_send(t) or not ("--type=worker_done" in t or any(t[i] == "--type" and t[i + 1] == "worker_done" for i in range(len(t) - 1))):
                continue
            for i, a in enumerate(t):
                nxt = t[i + 1] if i + 1 < len(t) else None
                if a == "--subject":
                    subj = nxt
                elif a.startswith("--subject="):
                    subj = a[10:]
                elif a == "--body":
                    body = nxt
                elif a.startswith("--body="):
                    body = a[7:]
                elif a == "--task-id":
                    task = nxt
            break
        else:
            return None
    else:
        if not re.search(r"(?:^|[;&|(\n])\s*(?:\S*/)?orca\s+orchestration\s+send\b.*--type[ =]worker_done", cmd):
            return None

        def opt(name):
            m = re.search(r"--%s(?:\s+|=)(?:\"([^\"]*)\"|'([^']*)'|(\S+))" % name, cmd)
            return next((g for g in m.groups() if g is not None), None) if m else None
        subj, body, task = opt("subject"), opt("body"), opt("task-id")
    verdict = ""
    for part in (subj, body):
        if not isinstance(part, str) or "$(" in part or "`" in part:
            continue
        m = VERDICT_RE.search(part)
        if m:
            verdict = m.group(1)
            break
    return verdict, task or ""


def tool_text(o, block):
    r = o.get("toolUseResult")
    if isinstance(r, dict) and isinstance(r.get("stdout"), str):
        return r["stdout"]
    c = block.get("content")
    return text_of(c) if not isinstance(c, str) else c


def feed(S, o, is_sub, mapped_cwd):
    """Folds one transcript line into the session. mapped_cwd(cwd) -> bool tells whether a cwd belongs to a mapped worktree."""
    t = o.get("type")
    ts = o.get("timestamp") if isinstance(o.get("timestamp"), str) else ""
    if ts:
        if not S["first"]:
            S["first"] = ts
        S["last"] = max(S["last"], ts)
    if isinstance(o.get("version"), str):
        S["version"] = o["version"]
    if not S["cwd"] and isinstance(o.get("cwd"), str) and o["cwd"] and not is_sub:
        S["cwd"] = o["cwd"]
        if S["kit"] is None and mapped_cwd(S["cwd"]):
            S["kit"] = True
    if t == "assistant":
        m = o.get("message") if isinstance(o.get("message"), dict) else {}
        model = m.get("model")
        if o.get("isApiErrorMessage") or model == "<synthetic>":
            S["apiErrors"] += 1
            return
        u = m.get("usage")
        if isinstance(u, dict):
            mid = m.get("id") or o.get("requestId") or o.get("uuid")
            if mid not in S["recent"]:
                if mid:
                    S["recent"].append(mid)
                    del S["recent"][:-RECENT_IDS]
                model = model if isinstance(model, str) else "unknown"
                if S["lastModel"] and S["lastModel"] != model:
                    S["modelChanges"] += 1
                S["lastModel"] = model
                r = model_row(S, model)
                inp, out = u.get("input_tokens") or 0, u.get("output_tokens") or 0
                cr, cw = u.get("cache_read_input_tokens") or 0, u.get("cache_creation_input_tokens") or 0
                h = min(((u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens") or 0), cw)
                det = u.get("output_tokens_details")
                r["input"] += inp
                r["output"] += out
                r["cacheRead"] += cr
                r["cacheCreation"] += cw
                r["cacheWrite1h"] += h
                r["cacheWrite5m"] += cw - h
                r["thinking"] += (det.get("thinking_tokens") or 0) if isinstance(det, dict) else 0
                r["turns"] += 1
                S["turns"] += 1
                S["maxContext"] = max(S["maxContext"], inp + cr + cw)
                c = cost_of(model, u)
                if c is None:
                    if model not in S["unpriced"]:
                        S["unpriced"].append(model)
                else:
                    for k in TYPES + ("webSearch",):
                        r["costByType"][k] += c[k]
                    r["cost"] += sum(c[k] for k in TYPES + ("webSearch",))
                    r["cacheSavings"] += c["saved"]
        content = m.get("content")
        for b in content if isinstance(content, list) else []:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            name = b.get("name") if isinstance(b.get("name"), str) else "unknown"
            tl = S["tools"].setdefault(name, {"calls": 0, "errors": 0, "seconds": 0.0})
            tl["calls"] += 1
            bid = b.get("id")
            if bid:
                S["pending"][bid] = [name, parse_ts(ts)]
                if len(S["pending"]) > 300:
                    S["pending"].pop(next(iter(S["pending"])))
            inp = b.get("input") if isinstance(b.get("input"), dict) else {}
            if name == "Bash" and isinstance(inp.get("command"), str):
                cmd = inp["command"]
                wd = worker_done_of(cmd)
                if wd is not None:
                    t0 = S["taskPrompts"].get(wd[1])
                    t1 = parse_ts(ts)
                    S["workerDone"].append({"verdict": wd[0], "seconds": round(t1 - t0) if t0 is not None and t1 is not None else None})
                elif git_commit_in(cmd) and bid:
                    S["special"][bid] = "commit"
                    if len(S["special"]) > 100:
                        S["special"].pop(next(iter(S["special"])))
            elif name == "Edit":
                S["locEdits"][0] += count_lines(inp.get("new_string"))
                S["locEdits"][1] += count_lines(inp.get("old_string"))
            elif name == "Write":
                S["locEdits"][0] += count_lines(inp.get("content"))
            elif name == "MultiEdit":
                for e in inp.get("edits") if isinstance(inp.get("edits"), list) else []:
                    if isinstance(e, dict):
                        S["locEdits"][0] += count_lines(e.get("new_string"))
                        S["locEdits"][1] += count_lines(e.get("old_string"))
    elif t == "user":
        m = o.get("message") if isinstance(o.get("message"), dict) else {}
        c = m.get("content")
        results = [b for b in c if isinstance(b, dict) and b.get("type") == "tool_result"] if isinstance(c, list) else []
        for b in results:
            p = S["pending"].pop(b.get("tool_use_id"), None)
            err = b.get("is_error") is True
            if p:
                tl = S["tools"].setdefault(p[0], {"calls": 0, "errors": 0, "seconds": 0.0})
                t1 = parse_ts(ts)
                if p[1] is not None and t1 is not None and t1 >= p[1]:
                    tl["seconds"] += t1 - p[1]
                if err:
                    tl["errors"] += 1
            if S["special"].pop(b.get("tool_use_id"), None) == "commit" and not err:
                txt = tool_text(o, b)
                a, d = INS_RE.search(txt), DEL_RE.search(txt)
                S["commits"][0] += 1
                S["commits"][1] += int(a.group(1)) if a else 0
                S["commits"][2] += int(d.group(1)) if d else 0
        if not results and not is_sub and not o.get("isMeta") and not o.get("isCompactSummary"):
            text = text_of(c)
            if text or isinstance(c, str):
                S["userMessages"] += 1
                if S["prompts"] < 3 and not S["role"]:
                    S["role"] = role_in(text)
                S["prompts"] += 1
                for tid in TASK_RE.findall(text):
                    if tid not in S["taskPrompts"] and len(S["taskPrompts"]) < 300:
                        S["taskPrompts"][tid] = parse_ts(ts)
                if S["kit"] is None and S["prompts"] == 1:
                    S["kit"] = True if S["role"] else False
    elif t == "cost-state" and not is_sub:
        added, removed = o.get("totalLinesAdded"), o.get("totalLinesRemoved")
        new = [o.get("totalCostUSD") if isinstance(o.get("totalCostUSD"), (int, float)) else None,
               added if isinstance(added, int) else None, removed if isinstance(removed, int) else None]
        if S["cs"] is None:
            S["cs"] = new
        else:   # cumulative counters never go down: keep the largest value seen of each
            S["cs"] = [n if o2 is None else (o2 if n is None else max(o2, n)) for o2, n in zip(S["cs"], new)]
    elif t == "api-request" and not is_sub:
        p = o.get("params") if isinstance(o.get("params"), dict) else {}
        oc = p.get("output_config") if isinstance(p.get("output_config"), dict) else {}
        if isinstance(oc.get("effort"), str) and oc["effort"]:
            S["effort"] = oc["effort"]
    elif t == "system" and o.get("subtype") == "compact_boundary":
        S["compactions"] += 1


def r6(x):
    return round(x, 6)


def snapshot(S, ts, task, project):
    models, tokens, cbt, saved, priced = {}, {k: 0 for k in ("input", "output", "cacheRead", "cacheCreation", "thinking")}, {k: 0.0 for k in TYPES + ("webSearch",)}, 0.0, 0.0
    for name, r in S["models"].items():
        models[name] = dict(r, cost=r6(r["cost"]), cacheSavings=r6(r["cacheSavings"]), costByType={k: r6(v) for k, v in r["costByType"].items()})
        for k in tokens:
            tokens[k] += r[k]
        for k in cbt:
            cbt[k] += r["costByType"][k]
        saved += r["cacheSavings"]
        priced += r["cost"]
    cs = S["cs"]
    cstate = cs[0] if cs else None
    if cs and cs[1] is not None and cs[2] is not None:
        lines = {"added": cs[1], "removed": cs[2], "source": "cost-state"}
    else:
        lines = {"added": S["locEdits"][0], "removed": S["locEdits"][1], "source": "edits"}
    return {
        "ts": ts, "session_id": S["sid"], "task": task, "project": project, "orca_roles_role": S["role"], "effort": S["effort"],
        "query_source": "main", "service_version": S["version"], "first": S["first"], "last": S["last"], "models": models, "tokens": tokens,
        "cost": r6(max(priced, cstate or 0.0)), "costPriced": r6(priced), "costState": cstate,
        "costByType": {k: r6(v) for k, v in cbt.items()}, "cacheSavings": r6(saved),
        "tools": {n: {"calls": v["calls"], "errors": v["errors"], "seconds": round(v["seconds"], 3)} for n, v in S["tools"].items()},
        "turns": S["turns"], "userMessages": S["userMessages"], "compactions": S["compactions"], "maxContext": S["maxContext"],
        "apiErrors": S["apiErrors"], "modelChanges": S["modelChanges"], "lines": lines, "workerDone": S["workerDone"],
        "commits": {"count": S["commits"][0], "insertions": S["commits"][1], "deletions": S["commits"][2]}, "unpriced": S["unpriced"],
    }


# ---------------------------------------------------------------- the pass
def read_jsonl(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if isinstance(o, dict):
                    out.append(o)
    except OSError:
        pass
    return out


def load_worktrees():
    """-> [(path, task, project)] longest path first; a later line for the same path wins."""
    m = {}
    for o in read_jsonl(os.path.join(MDIR, "worktrees.jsonl")):
        for k in ("path", "physical"):
            p = o.get(k)
            if isinstance(p, str) and p:
                m[p.rstrip("/") or "/"] = (str(o.get("task") or ""), str(o.get("project") or ""))
    return sorted(((p, v[0], v[1]) for p, v in m.items()), key=lambda x: -len(x[0]))


def wt_match(wts, cwd):
    c = cwd.rstrip("/") or "/"
    for p, task, project in wts:
        if c == p or c.startswith(p + "/"):
            return task, project
    return None


def claude_root():
    r = os.environ.get("ORCA_ROLES_CLAUDE_PROJECTS")
    return r if r else os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"), "projects")


def discover(root):
    """-> {path: (size, is_sub, session id)}; the session id comes from the path (<sid>.jsonl, <sid>/subagents/*.jsonl)."""
    found = {}
    try:
        projects = [e for e in os.scandir(root) if e.is_dir(follow_symlinks=False)]
    except OSError:
        return found
    for pd in projects:
        try:
            entries = list(os.scandir(pd.path))
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_file() and e.name.endswith(".jsonl"):
                    found[e.path] = (e.stat().st_size, False, e.name[:-6])
                elif e.is_dir(follow_symlinks=False):
                    sub = os.path.join(e.path, "subagents")
                    if os.path.isdir(sub):
                        for s in os.scandir(sub):
                            if s.is_file() and s.name.endswith(".jsonl"):
                                found[s.path] = (s.stat().st_size, True, e.name)
            except OSError:
                continue
    return found


def head_of(path):
    try:
        with open(path, "rb") as f:
            return f.read(64).hex()
    except OSError:
        return ""


def load_state():
    try:
        with open(os.path.join(MDIR, "state.json")) as f:
            s = json.load(f)
        if isinstance(s, dict) and s.get("v") == 1:
            return s
    except (OSError, ValueError):
        pass
    return {"v": 1, "lastPass": "", "lastRotation": "", "wt": "", "files": {}, "sessions": {}}


def save_state(state):
    tmp = os.path.join(MDIR, "state.json.tmp.%d" % os.getpid())
    with open(tmp, "w") as f:
        json.dump(state, f, separators=(",", ":"))
    os.replace(tmp, os.path.join(MDIR, "state.json"))


def reset_session(state, sid):
    state["sessions"].pop(sid, None)
    for e in state["files"].values():
        if e["session"] == sid:
            e.update(offset=0, size=0, head="", ignored=False, more=False)


def compute(state, root, deadline, wts, wt_changed):
    """Reads the new transcript bytes into state; returns the ids of the kit sessions that changed. wts() gives the worktrees map when needed."""
    found = discover(root)
    files = state["files"]
    for p in [p for p in files if p not in found]:
        sid = files.pop(p)["session"]
        if not any(e["session"] == sid for e in files.values()):
            state["sessions"].pop(sid, None)
    for p, (size, is_sub, sid) in found.items():
        e = files.get(p)
        if e and size != e["size"] and (size < e["offset"] or e["head"] != head_of(p)[:len(e["head"])]):
            reset_session(state, sid)
    mapped = lambda cwd: wt_match(wts(), cwd) is not None
    if wt_changed:   # a worktree mapped after its session was ignored
        for e in list(files.values()):
            if e.get("ignored") and e.get("cwd") and mapped(e["cwd"]):
                reset_session(state, e["session"])
    changed = set()
    for p in sorted(found, key=lambda x: found[x][1]):
        size, is_sub, sid = found[p]
        e = files.setdefault(p, {"offset": 0, "size": 0, "head": "", "session": sid, "ignored": False, "more": False})
        if e["ignored"] or (size == e["size"] and not e["more"]):
            e["size"] = size if e["ignored"] else e["size"]
            continue
        S = state["sessions"].get(sid)
        if S is None:
            if is_sub:
                continue
            S = state["sessions"][sid] = new_session(sid)
        if time.time() > deadline:
            break
        try:
            with open(p, "rb") as f:
                if not e["head"]:
                    e["head"] = f.read(64).hex()
                f.seek(e["offset"])
                consumed, n = 0, 0
                e["more"] = False
                for raw in f:
                    if not raw.endswith(b"\n"):
                        break
                    consumed += len(raw)
                    n += 1
                    try:
                        o = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(o, dict):
                        feed(S, o, is_sub, mapped)
                    if S["kit"] is False:
                        break
                    if n % 2000 == 0 and time.time() > deadline:
                        e["more"] = True
                        break
                e["offset"] += consumed
        except OSError as ex:
            log("cannot read %s: %s" % (os.path.basename(p), ex))
            continue
        e["size"] = size
        if S["kit"] is False:
            for fe in files.values():
                if fe["session"] == sid:
                    fe.update(ignored=True, cwd=S["cwd"])
            state["sessions"].pop(sid, None)
            continue
        changed.add(sid)
    return {sid for sid in changed if sid in state["sessions"] and state["sessions"][sid]["kit"]}


def store(state, changed, wts, ts):  # wts: the worktrees map
    """Appends the snapshot of each changed session to today's daily file."""
    if not changed:
        return
    path = os.path.join(MDIR, "sessions-%s.jsonl" % ts[:10])
    with open(path, "a") as f:
        for sid in sorted(changed):
            S = state["sessions"][sid]
            hit = wt_match(wts, S["cwd"]) if S["cwd"] else None
            f.write(json.dumps(snapshot(S, ts, hit[0] if hit else "", hit[1] if hit else ""), separators=(",", ":")) + "\n")


def rotate(state, today, keep_days):
    if state.get("lastRotation") == today:
        return
    limit = (datetime.date.fromisoformat(today) - datetime.timedelta(days=keep_days)).isoformat()
    try:
        for name in os.listdir(MDIR):
            m = re.match(r"^sessions-(\d{4}-\d\d-\d\d)\.jsonl$", name)
            if m and m.group(1) < limit:
                try:
                    os.remove(os.path.join(MDIR, name))
                except OSError as ex:
                    log("cannot remove %s: %s" % (name, ex))
    except OSError:
        pass
    state["lastRotation"] = today


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def take_lock():
    lock = os.path.join(MDIR, "pass.lock")
    for _ in range(2):
        try:
            os.mkdir(lock)
        except FileExistsError:
            try:
                with open(os.path.join(lock, "pid")) as f:
                    pid = int(f.read().strip())
                stale = not pid_alive(pid)
            except (OSError, ValueError):
                try:
                    stale = time.time() - os.stat(lock).st_mtime > 120
                except OSError:
                    stale = True
            if not stale:
                return None
            for n in ("pid",):
                try:
                    os.remove(os.path.join(lock, n))
                except OSError:
                    pass
            try:
                os.rmdir(lock)
            except OSError:
                return None
            continue
        with open(os.path.join(lock, "pid"), "w") as f:
            f.write("%d\n" % os.getpid())
        return lock
    return None


def once():
    if metrics_settings().get("enabled") is False:
        return 0
    os.makedirs(MDIR, exist_ok=True)
    lock = take_lock()
    if lock is None:
        return 0
    try:
        deadline = time.time() + LIMIT
        ts = now_iso()
        state = load_state()
        wt_path = os.path.join(MDIR, "worktrees.jsonl")
        try:
            st = os.stat(wt_path)
            wt_sig = "%d:%d" % (st.st_size, st.st_mtime_ns)
        except OSError:
            wt_sig = ""
        cache = []

        def wts():
            if not cache:
                cache.append(load_worktrees())
            return cache[0]
        wt_changed = state.get("wt") != wt_sig
        state["wt"] = wt_sig
        changed = compute(state, claude_root(), deadline, wts, wt_changed)
        if changed:
            store(state, changed, wts(), ts)
        rotate(state, ts[:10], retention_days())
        state["lastPass"] = ts
        save_state(state)
        return 0
    except Exception as ex:   # never loud: the scheduler runs this
        log("pass failed: %s: %s" % (type(ex).__name__, ex))
        return 1
    finally:
        try:
            os.remove(os.path.join(lock, "pid"))
            os.rmdir(lock)
        except OSError:
            pass
        trim_log()


# ---------------------------------------------------------------- report
def zero():
    return {"sessions": 0, "tokens": {"input": 0, "output": 0, "cacheRead": 0, "cacheCreation": 0, "thinking": 0}, "cost": 0.0,
            "costByType": {k: 0.0 for k in TYPES + ("webSearch",)}, "cacheSavings": 0.0}


def add(acc, tokens, cost, cbt, saved, sessions=1):
    acc["sessions"] += sessions
    for k in acc["tokens"]:
        acc["tokens"][k] += tokens.get(k, 0)
    acc["cost"] += cost
    for k in acc["costByType"]:
        acc["costByType"][k] += cbt.get(k, 0.0)
    acc["cacheSavings"] += saved


def report(args):
    task, since, as_json = None, None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--task" and i + 1 < len(args):
            task = args[i + 1]
            i += 1
        elif a == "--since" and i + 1 < len(args):
            since = args[i + 1]
            i += 1
        elif a == "--json":
            as_json = True
        else:
            print("usage-metrics.sh --report [--task <t>] [--since <YYYY-MM-DD>] [--json]", file=sys.stderr)
            return 2
        i += 1
    if since is not None and not re.match(r"^\d{4}-\d\d-\d\d$", since):
        print("usage-metrics.sh: --since must be a date (YYYY-MM-DD)", file=sys.stderr)
        return 2
    latest = {}
    try:
        names = sorted(n for n in os.listdir(MDIR) if re.match(r"^sessions-\d{4}-\d\d-\d\d\.jsonl$", n))
    except OSError:
        names = []
    for n in names:
        for o in read_jsonl(os.path.join(MDIR, n)):
            sid = o.get("session_id")
            if sid and (sid not in latest or str(o.get("ts")) >= str(latest[sid].get("ts"))):
                latest[sid] = o
    total, by_task, by_role, by_model = zero(), {}, {}, {}
    for o in latest.values():
        if task is not None and o.get("task") != task:
            continue
        if since is not None and str(o.get("last") or "")[:10] < since:
            continue
        tk, cost, cbt, saved = o.get("tokens") or {}, o.get("cost") or 0.0, o.get("costByType") or {}, o.get("cacheSavings") or 0.0
        add(total, tk, cost, cbt, saved)
        add(by_task.setdefault(o.get("task") or "", zero()), tk, cost, cbt, saved)
        add(by_role.setdefault(o.get("orca_roles_role") or "", zero()), tk, cost, cbt, saved)
        for m, r in (o.get("models") or {}).items():
            add(by_model.setdefault(m, zero()), r, r.get("cost") or 0.0, r.get("costByType") or {}, r.get("cacheSavings") or 0.0)

    def rnd(a):
        return {"sessions": a["sessions"], "tokens": a["tokens"], "cost": r6(a["cost"]), "costByType": {k: r6(v) for k, v in a["costByType"].items()},
                "cacheSavings": r6(a["cacheSavings"])}
    res = {"task": task, "since": since, "total": rnd(total), "byTask": {k: rnd(v) for k, v in sorted(by_task.items())},
           "byRole": {k: rnd(v) for k, v in sorted(by_role.items())}, "byModel": {k: rnd(v) for k, v in sorted(by_model.items())}}
    if as_json:
        print(json.dumps(res, separators=(",", ":")))
        return 0

    def row(name, a):
        t = a["tokens"]
        return "%-28s %4d sessions  $%9.4f  saved $%8.4f  in %d out %d cacheRead %d cacheWrite %d" % (
            name or "(none)", a["sessions"], a["cost"], a["cacheSavings"], t["input"], t["output"], t["cacheRead"], t["cacheCreation"])
    print(row("total", res["total"]))
    for title, key in (("task", "byTask"), ("role", "byRole"), ("model", "byModel")):
        print("by %s:" % title)
        for k, v in sorted(res[key].items(), key=lambda kv: -kv[1]["cost"]):
            print("  " + row(k, v))
    return 0


def main(argv):
    if len(argv) >= 1 and argv[0] == "--once" and len(argv) == 1:
        return once()
    if len(argv) >= 1 and argv[0] == "--report":
        return report(argv[1:])
    print("usage: usage-metrics.sh --once | --report [--task <t>] [--since <YYYY-MM-DD>] [--json]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
