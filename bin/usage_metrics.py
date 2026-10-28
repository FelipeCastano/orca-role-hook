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

Live push (after the store, in the same pass): OTLP/HTTP JSON (application/json) to settings.metrics.otlpEndpoint, one ResourceMetrics per session,
cumulative monotonic Sums (Gauges where noted), startTime = the session's first line, time = now. Only sessions with new transcript lines since their
last successful push (position kept in state.json) are sent; a session never pushed is sent only when its last line is under 15 minutes old (older
ones are history: step 5). A non-loopback endpoint (or prometheusUrl) without settings.metrics.allowRemote true sends nothing and warns once per UTC
day; connection errors/timeouts (5 s, ORCA_ROLES_METRICS_HTTP_TIMEOUT) are silent and retried next pass. Resource attributes: service.name=claude-code,
service.version, session.id, task, orca_roles.role and the constant labels (user_*, organization_id, host_arch, os_type, os_version, terminal_type,
copied once a day from the newest claude_code_* series of prometheusUrl /api/v1/series; omitted when unavailable); never job/instance/project. Before
a session's first push its old series (session_id) are read from Prometheus and continued: value = old last + (transcript cumulative now - transcript
cumulative at the anchor, the last point where the transcript equals the old value exactly, else at the old last sample time), with the old series'
labels; old counters that reset -> the session is not pushed (logged once); Prometheus unreachable -> the first push waits.
Instrument -> Prometheus name (collector: resource_to_telemetry_conversion, unit and _total suffixes):
  claude_code.cost.usage (USD)            claude_code_cost_usage_USD_total{model,effort,query_source}   (priced cost per model)
  claude_code.token.usage (tokens)        claude_code_token_usage_tokens_total{type,model,effort,query_source}
  claude_code.session.count               claude_code_session_count_total{start_type}
  orca_roles.cost.by_type (USD)           orca_roles_cost_by_type_USD_total{type,model}
  orca_roles.cache.savings (USD, gauge)   orca_roles_cache_savings_USD{model}
  orca_roles.thinking (tokens)            orca_roles_thinking_tokens_total{model}
  orca_roles.tool.calls / .errors         orca_roles_tool_calls_total{tool} / orca_roles_tool_errors_total{tool}
  orca_roles.tool.duration (s)            orca_roles_tool_duration_seconds_total{tool}
  orca_roles.turns / .user.messages / .compactions / .api.errors / .model.changes
                                          orca_roles_turns_total / orca_roles_user_messages_total / orca_roles_compactions_total / orca_roles_api_errors_total / orca_roles_model_changes_total
  orca_roles.context.max (tokens, gauge)  orca_roles_context_max_tokens
  orca_roles.lines                        orca_roles_lines_total{type=added|removed}
  orca_roles.verdicts                     orca_roles_verdicts_total{verdict=ACCEPTED|REJECTED|none}
  orca_roles.task.duration (s)            orca_roles_task_duration_seconds_total{verdict}
  orca_roles.commits                      orca_roles_commits_total
  orca_roles.commit.lines                 orca_roles_commit_lines_total{type=insertions|deletions}
  orca_roles.kit.events                   orca_roles_kit_events_total{event=launch|reopened|detached-kept|relaunch,role,task,project}
  orca_roles.dispatch.outcomes            orca_roles_dispatch_outcomes_total{outcome=dispatch|started|enter-resent|not-started|no-check,role,task,project}
The last two come from $KIT/metrics/events.jsonl, not from a session: counts per (task, project, event, role), task/project from worktrees.jsonl by the
event's worktree path ('' if unmapped), pushed under one resource (service.name=claude-code, no session.id) only when a count changed.

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
import urllib.error
import urllib.parse
import urllib.request

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


# ---------------------------------------------------------------- live push (OTLP/HTTP JSON to the local collector)
HTTP_TIMEOUT = float(os.environ.get("ORCA_ROLES_METRICS_HTTP_TIMEOUT", "5"))
BATCH = 25
HISTORY_WINDOW = 900   # a session never pushed is pushed only when its last line is this recent (seconds); older ones are history (step 5)
DATAPOINT_LABELS = ("model", "type", "effort", "query_source", "start_type", "decision", "source", "tool_name", "language", "verdict", "tool")
CLAUDE_SERIES = ("claude_code_cost_usage_USD_total", "claude_code_token_usage_tokens_total", "claude_code_session_count_total")
LOOPBACK = ("127.0.0.1", "::1", "localhost")


class Down(Exception):
    """A connection failed or timed out: the rest of the pass skips that server."""


def _opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def http_json(url, body=None, timeout=None):
    """-> (status, parsed JSON or None). Raises Down on a connection error or timeout."""
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body, separators=(",", ":")).encode(),
                                 headers={"Content-Type": "application/json"} if body is not None else {}, method="POST" if body is not None else "GET")
    try:
        with _opener().open(req, timeout=timeout or HTTP_TIMEOUT) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    except (urllib.error.URLError, OSError, ValueError):
        raise Down()
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, None


def push_settings():
    m = metrics_settings()
    def url(k, d):
        v = m.get(k)
        return v if isinstance(v, str) and re.match(r"^https?://.", v) else d
    return (url("otlpEndpoint", "http://127.0.0.1:4318/v1/metrics"), url("prometheusUrl", "http://127.0.0.1:9090"), m.get("allowRemote") is True)


def host_ok(url, allow_remote, state, what):
    """Loopback hosts only, unless allowRemote; one warning line per UTC day otherwise."""
    host = urllib.parse.urlparse(url).hostname or ""
    if allow_remote or host in LOOPBACK:
        return True
    today = now_iso()[:10]
    warned = state.setdefault("warned", {})
    if warned.get(what) != today:
        warned[what] = today
        log("not pushing: %s %s is not on this machine and settings.metrics.allowRemote is not true" % (what, host))
    return False


def sel(name, labels):
    return "%s{%s}" % (name, ",".join('%s="%s"' % (k, str(v).replace("\\", "\\\\").replace('"', '\\"')) for k, v in sorted(labels.items())))


def prom_vector(base, query):
    st, js = http_json("%s/api/v1/query?%s" % (base.rstrip("/"), urllib.parse.urlencode({"query": query})))
    if st != 200 or not isinstance(js, dict) or js.get("status") != "success":
        raise Down()
    return (js.get("data") or {}).get("result") or []


def prom_series(base, match, start=None):
    q = {"match[]": match}
    if start is not None:
        q["start"] = "%d" % start
        q["end"] = "%d" % time.time()
    st, js = http_json("%s/api/v1/series?%s" % (base.rstrip("/"), urllib.parse.urlencode(q)))
    if st != 200 or not isinstance(js, dict) or js.get("status") != "success":
        raise Down()
    return [s for s in (js.get("data") or []) if isinstance(s, dict)]


def is_constant_label(k):
    return k.startswith("user_") or k in ("organization_id", "host_arch", "os_type", "os_version", "terminal_type")


def refresh_constants(state, prom):
    """The constant labels, copied once a day from the newest existing claude_code_* series; keeps the cached ones when Prometheus is down."""
    c = state.setdefault("constants", {"day": "", "labels": {}})
    today = now_iso()[:10]
    if c.get("day") == today:
        return c["labels"]
    labels = {}
    for days in (1, 7, 90):
        found = prom_series(prom, '{__name__=~"claude_code_.+"}', time.time() - days * 86400)
        if found:
            labels = {k: v for k, v in found[-1].items() if isinstance(v, str) and is_constant_label(k)}
            break
    c["day"], c["labels"] = today, labels
    return labels


def session_timeline(state, sid):
    """-> (times, prefix) of the session's transcript read from the start: the responses in time order (deduplicated by message id) and, per
    (model, kind), the running totals after each response; kinds are the token types and 'cost'."""
    entries, seen = [], set()
    for p, e in state["files"].items():
        if e["session"] != sid or e.get("ignored"):
            continue
        try:
            with open(p, "rb") as f:
                for raw in f:
                    if not raw.endswith(b"\n") or b'"usage"' not in raw:
                        continue
                    try:
                        o = json.loads(raw)
                    except ValueError:
                        continue
                    m = o.get("message") if isinstance(o, dict) and o.get("type") == "assistant" else None
                    if not isinstance(m, dict) or not isinstance(m.get("usage"), dict) or o.get("isApiErrorMessage") or m.get("model") == "<synthetic>":
                        continue
                    mid = m.get("id") or o.get("requestId") or o.get("uuid")
                    if mid in seen:
                        continue
                    seen.add(mid)
                    u, model = m["usage"], m.get("model") if isinstance(m.get("model"), str) else "unknown"
                    c = cost_of(model, u)
                    entries.append((parse_ts(o.get("timestamp")) or 0.0, model, {
                        "input": u.get("input_tokens") or 0, "output": u.get("output_tokens") or 0,
                        "cacheRead": u.get("cache_read_input_tokens") or 0, "cacheCreation": u.get("cache_creation_input_tokens") or 0,
                        "cost": sum(c[k] for k in TYPES + ("webSearch",)) if c else 0.0}))
        except OSError:
            continue
    entries.sort(key=lambda x: x[0])
    run, prefix = {}, {}
    for n, (_, model, v) in enumerate(entries):
        for kind, x in v.items():
            run[(model, kind)] = run.get((model, kind), 0) + x
        for key in run:
            prefix.setdefault(key, [0] * n).append(run[key])
        for key, lst in prefix.items():
            if len(lst) <= n:
                lst.append(run.get(key, 0))
    return [e[0] for e in entries], prefix


def continuation(state, sid, prom, now):
    """The old series of the session in Prometheus. -> None when its counters reset (not continued), else
    {"res": resource labels of the old series, "off": {key: offset}, "lab": {key: {"effort": old effort}}}."""
    old = [s for s in prom_series(prom, '{session_id="%s"}' % sid) if s.get("__name__") in CLAUDE_SERIES and s.get("query_source", "main") == "main"]
    if not old:
        return {"res": {}, "off": {}, "lab": {}, "tlast": {}}
    times, prefix = session_timeline(state, sid)
    info = []
    for s in old:
        selector = sel(s["__name__"], {k: v for k, v in s.items() if k != "__name__"})
        resets = prom_vector(prom, "resets(%s[90d])" % selector)
        if any(float(r["value"][1]) > 0 for r in resets):
            return None
        val = prom_vector(prom, "last_over_time(%s[90d])" % selector)
        at = prom_vector(prom, "timestamp(last_over_time(%s[90d]))" % selector)
        if not val or not at:
            continue
        info.append((s, float(val[0]["value"][1]), float(at[0]["value"][1])))
    res = {}
    for s, _, _ in info:
        for k, v in s.items():
            if k in ("__name__", "job", "instance", "session_id") or k in DATAPOINT_LABELS:
                continue
            res.setdefault(k, v)
    off, lab, anchor, tlast = {}, {}, {}, {}
    def idx_at(t):
        i = -1
        for j, x in enumerate(times):
            if x <= t:
                i = j
        return i
    for s, v, t_last in info:   # token series first: the anchor is the last point where the transcript equals the old value exactly
        if s["__name__"] != CLAUDE_SERIES[1]:
            continue
        kind = s.get("type")
        series = prefix.get((s.get("model"), kind), [])
        top = idx_at(t_last)
        hit = -1
        for j in range(min(top + 1, len(series))):
            if abs(series[j] - v) < 0.5:
                hit = j
        i = hit if hit >= 0 else top
        anchor[s.get("model")] = max(anchor.get(s.get("model"), -1), i) if hit >= 0 else anchor.get(s.get("model"), -1)
        key = "%s|%s|%s" % (CLAUDE_SERIES[1], s.get("model"), kind)
        off[key] = v - (series[i] if 0 <= i < len(series) else 0)
        lab[key] = {"effort": s.get("effort", "medium")}
        tlast[key] = t_last
    for s, v, t_last in info:
        if s["__name__"] == CLAUDE_SERIES[0]:
            series = prefix.get((s.get("model"), "cost"), [])
            i = anchor.get(s.get("model"), -1)
            if i < 0:
                i = idx_at(t_last)
            key = "%s|%s|" % (CLAUDE_SERIES[0], s.get("model"))
            off[key] = v - (series[i] if 0 <= i < len(series) else 0.0)
            lab[key] = {"effort": s.get("effort", "medium")}
            tlast[key] = t_last
        elif s["__name__"] == CLAUDE_SERIES[2]:
            key = "%s||" % CLAUDE_SERIES[2]
            off[key] = v - 1
            lab[key] = {"start_type": s.get("start_type", "fresh")}
            tlast[key] = t_last
    return {"res": res, "off": off, "lab": lab, "tlast": tlast}


def str_attrs(d):
    return [{"key": k, "value": {"stringValue": str(v)}} for k, v in d.items() if v not in (None, "")]


def session_points(S, P):
    """-> [(metric name, unit, kind, attrs, value, key)] for one session; kind 'sum' (cumulative, monotonic) or 'gauge'."""
    pts = []
    def add_pt(name, unit, kind, attrs, value, base=None):
        pts.append((name, unit, kind, attrs, value, base))
    eff = S["effort"]
    for model, r in S["models"].items():
        for typ, k in (("input", "input"), ("output", "output"), ("cacheRead", "cacheRead"), ("cacheCreation", "cacheCreation")):
            base = "%s|%s|%s" % (CLAUDE_SERIES[1], model, typ)
            e = (P["lab"].get(base) or {}).get("effort", eff)
            add_pt("claude_code.token.usage", "tokens", "sum", {"type": typ, "model": model, "effort": e, "query_source": "main"}, r[k], base)
        base = "%s|%s|" % (CLAUDE_SERIES[0], model)
        e = (P["lab"].get(base) or {}).get("effort", eff)
        add_pt("claude_code.cost.usage", "USD", "sum", {"model": model, "effort": e, "query_source": "main"}, r["cost"], base)
        for typ, v in r["costByType"].items():
            add_pt("orca_roles.cost.by_type", "USD", "sum", {"type": typ, "model": model}, v)
        add_pt("orca_roles.cache.savings", "USD", "gauge", {"model": model}, r["cacheSavings"])
        add_pt("orca_roles.thinking", "tokens", "sum", {"model": model}, r["thinking"])
    base = "%s||" % CLAUDE_SERIES[2]
    add_pt("claude_code.session.count", "", "sum", {"start_type": (P["lab"].get(base) or {}).get("start_type", "fresh")}, 1, base)
    for tool, v in S["tools"].items():
        add_pt("orca_roles.tool.calls", "", "sum", {"tool": tool}, v["calls"])
        add_pt("orca_roles.tool.duration", "s", "sum", {"tool": tool}, v["seconds"])
        add_pt("orca_roles.tool.errors", "", "sum", {"tool": tool}, v["errors"])
    for name, v in (("orca_roles.turns", S["turns"]), ("orca_roles.user.messages", S["userMessages"]), ("orca_roles.compactions", S["compactions"]),
                    ("orca_roles.api.errors", S["apiErrors"]), ("orca_roles.model.changes", S["modelChanges"]), ("orca_roles.commits", S["commits"][0])):
        add_pt(name, "", "sum", {}, v)
    add_pt("orca_roles.context.max", "tokens", "gauge", {}, S["maxContext"])
    cs = S["cs"]
    if cs and cs[1] is not None and cs[2] is not None:
        added, removed = cs[1], cs[2]
    else:
        added, removed = S["locEdits"]
    add_pt("orca_roles.lines", "", "sum", {"type": "added"}, added)
    add_pt("orca_roles.lines", "", "sum", {"type": "removed"}, removed)
    add_pt("orca_roles.commit.lines", "", "sum", {"type": "insertions"}, S["commits"][1])
    add_pt("orca_roles.commit.lines", "", "sum", {"type": "deletions"}, S["commits"][2])
    verdicts, secs = {}, {}
    for w in S["workerDone"]:
        v = w.get("verdict") or "none"
        verdicts[v] = verdicts.get(v, 0) + 1
        secs[v] = secs.get(v, 0) + (w.get("seconds") or 0)
    for v in verdicts:
        add_pt("orca_roles.verdicts", "", "sum", {"verdict": v}, verdicts[v])
        add_pt("orca_roles.task.duration", "s", "sum", {"verdict": v}, secs[v])
    return pts


def resource_of(S, P, constants, task):
    """The resource attributes the collector turns into labels (resource_to_telemetry_conversion): a continued session keeps the labels of its old
    series; a new one gets the constant labels. No job/instance, no project."""
    attrs = {"service.name": "claude-code"}
    for k, v in (P["res"] or constants).items():
        if k not in ("service_name", "service_version"):
            attrs[k] = v
    attrs["service.version"] = P["res"].get("service_version") or S["version"]
    attrs["session.id"] = S["sid"]
    if not P["res"]:
        if task:
            attrs["task"] = task
        if S["role"]:
            attrs["orca_roles.role"] = S["role"]
    return attrs


def otlp_resource(S, P, constants, task, now_ns):
    vals = P["vals"]
    by_name = {}
    for name, unit, kind, attrs, value, base in session_points(S, P):
        key = name + "|" + "|".join("%s=%s" % kv for kv in sorted(attrs.items()))
        v = float(value) + (P["off"].get(base, 0) if base else 0)
        if kind == "sum":
            v = max(v, vals.get(key, 0.0))
        vals[key] = v   # provisional: committed to state only after a successful push
        m = by_name.setdefault(name, {"name": name, "unit": unit, "kind": kind, "points": []})
        dp = {"attributes": str_attrs(attrs), "timeUnixNano": str(now_ns), "asDouble": v}
        if kind == "sum":
            dp["startTimeUnixNano"] = str(int((parse_ts(S["first"]) or time.time()) * 1e9))
        m["points"].append(dp)
    metrics = []
    for m in by_name.values():
        body = {"dataPoints": m["points"]}
        if m["kind"] == "sum":
            body.update(aggregationTemporality=2, isMonotonic=True)
        metrics.append(dict({"name": m["name"], "unit": m["unit"]}, **{m["kind"]: body}))
    return {"resource": {"attributes": str_attrs(resource_of(S, P, constants, task))},
            "scopeMetrics": [{"scope": {"name": "orca-roles.usage-metrics"}, "metrics": metrics}]}


def session_positions(state):
    pos = {}
    for e in state["files"].values():
        pos[e["session"]] = pos.get(e["session"], 0) + e["offset"]
    return pos


def push(state):
    """Pushes the sessions that have new transcript lines since their last successful push. Never loud; a failure leaves them pending."""
    otlp, prom, allow = push_settings()
    pos = session_positions(state)
    now = time.time()
    pending = []
    pushed = state.setdefault("pushed", {})   # per session, outside the session object: it survives a recompute (the counters never go down)
    for sid, S in state["sessions"].items():
        if not S.get("kit"):
            continue
        P = pushed.get(sid)
        if P is None:
            P = pushed[sid] = S.pop("push", None) or {"pos": None, "state": "", "off": {}, "lab": {}, "res": {}, "vals": {}, "seen": now}
        if P["pos"] != pos.get(sid):
            P["seen"] = now
        if P["state"] == "reset":   # its old counters reset: never pushed
            P["pos"] = pos.get(sid)
            continue
        if P["state"] == "history" and P["pos"] == pos.get(sid):
            continue
        if P["state"] == "history":   # new lines in a session that was history: live from now on
            P["state"], P["pos"] = "", None
        if P["pos"] is None and P["state"] == "" and now - (parse_ts(S["last"]) or 0) > HISTORY_WINDOW:
            P["state"], P["pos"] = "history", pos.get(sid)   # finished before the live push existed: history is step 5's
            continue
        if P["pos"] != pos.get(sid) or P["pos"] is None:
            pending.append(sid)
    if not pending:
        return
    if not host_ok(otlp, allow, state, "otlpEndpoint"):
        return
    prom_ok = host_ok(prom, allow, state, "prometheusUrl")
    prom_down = not prom_ok
    constants = None
    ready = []
    for sid in pending:
        S = state["sessions"][sid]
        P = pushed[sid]
        if P["state"] == "" and not P.get("cont"):
            if prom_down:
                continue
            try:
                c = continuation(state, sid, prom, now)
            except Down:
                prom_down = True
                continue
            if c is None:
                P["state"], P["pos"] = "reset", pos.get(sid)
                log("session %s not continued: its old counters in Prometheus reset" % sid)
                continue
            P.update(off=c["off"], lab=c["lab"], res=c["res"], tlast=c["tlast"], cont=True)
        if constants is None and not P["res"]:
            try:
                constants = refresh_constants(state, prom) if not prom_down else state.get("constants", {}).get("labels", {})
            except Down:
                prom_down = True
                constants = state.get("constants", {}).get("labels", {})
        ready.append(sid)
    if not ready:
        return
    now_ns = int(now * 1e9)
    wts = load_worktrees()

    def task_of(sid):
        hit = wt_match(wts, state["sessions"][sid]["cwd"]) if state["sessions"][sid]["cwd"] else None
        return hit[0] if hit else ""
    for i in range(0, len(ready), BATCH):
        chunk = ready[i:i + BATCH]
        saved = {sid: dict(pushed[sid]["vals"]) for sid in chunk}
        body = {"resourceMetrics": [otlp_resource(state["sessions"][sid], pushed[sid], constants or {}, task_of(sid), now_ns) for sid in chunk]}
        try:
            st, _ = http_json(otlp, body)
        except Down:
            st = None
        if st is not None and 200 <= st < 300:
            for sid in chunk:
                pushed[sid]["pos"] = pos.get(sid)
                pushed[sid].setdefault("first", now)   # when this session's series began in Prometheus: a backfill ends before it
        else:
            for sid in chunk:
                pushed[sid]["vals"] = saved[sid]
            if st is not None:
                log("push refused: HTTP %s" % st)
            return


# ---------------------------------------------------------------- kit events (events.jsonl -> orca_roles.kit.events / orca_roles.dispatch.outcomes)
OUTCOME_EVENTS = ("dispatch", "started", "enter-resent", "not-started", "no-check")
KIT_EVENTS = ("launch", "reopened", "detached-kept", "relaunch")
SEP = "\t"


def tally_events(lines, wts, counts):
    for o in lines:
        ev, wt = o.get("event"), o.get("worktree")
        if ev not in OUTCOME_EVENTS + KIT_EVENTS or not isinstance(wt, str):
            continue
        hit = wt_match(wts, wt) if wt else None
        key = SEP.join((hit[0] if hit else "", hit[1] if hit else "", ev, str(o.get("role") or "")))
        counts[key] = counts.get(key, 0) + 1


def read_events(state, wts):
    """Reads the new complete lines of events.jsonl (byte offset in state['events']); a file that shrank is read again from the start."""
    E = state.setdefault("events", {"offset": 0, "counts": {}, "floor": {}, "start": None})
    try:
        with open(os.path.join(MDIR, "events.jsonl"), "rb") as f:
            size = os.fstat(f.fileno()).st_size
            if size < E["offset"]:
                E["offset"], E["counts"] = 0, {}
            f.seek(E["offset"])
            data = f.read(size - E["offset"])
    except OSError:
        return E
    end = data.rfind(b"\n") + 1
    lines = []
    for raw in data[:end].splitlines():
        try:
            o = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        if isinstance(o, dict):
            lines.append(o)
    if lines:
        tally_events(lines, wts(), E["counts"])
    E["offset"] += end
    return E


def events_resource(E, now_ns):
    """The ResourceMetrics of the kit events; vals are committed to E['floor'] only after a successful push."""
    metrics = {}
    start = str(int((E["start"] or time.time()) * 1e9))
    new_floor = {}
    for key, n in sorted(E["counts"].items()):
        task, project, ev, role = key.split(SEP)
        n = max(n, E["floor"].get(key, 0))
        new_floor[key] = n
        name, label = ("orca_roles.dispatch.outcomes", "outcome") if ev in OUTCOME_EVENTS else ("orca_roles.kit.events", "event")
        m = metrics.setdefault(name, {"name": name, "unit": "", "sum": {"dataPoints": [], "aggregationTemporality": 2, "isMonotonic": True}})
        m["sum"]["dataPoints"].append({"attributes": str_attrs({label: ev, "role": role, "task": task, "project": project}),
                                       "startTimeUnixNano": start, "timeUnixNano": str(now_ns), "asDouble": float(n)})
    for key, n in E["floor"].items():   # a key the file no longer yields keeps its last value
        if key not in new_floor:
            new_floor[key] = n
    res = {"resource": {"attributes": str_attrs({"service.name": "claude-code"})},
           "scopeMetrics": [{"scope": {"name": "orca-roles.usage-metrics"}, "metrics": list(metrics.values())}]}
    return res, new_floor


def push_events(state, wts):
    """Reads the new events and pushes the counts that changed since the last successful push. Never loud."""
    E = read_events(state, wts)
    if not any(n > E["floor"].get(k, 0) for k, n in E["counts"].items()):
        return
    otlp, _, allow = push_settings()
    if not host_ok(otlp, allow, state, "otlpEndpoint"):
        return
    now = time.time()
    if E["start"] is None:
        E["start"] = now
    res, new_floor = events_resource(E, int(now * 1e9))
    try:
        st, _ = http_json(otlp, {"resourceMetrics": [res]})
    except Down:
        return
    if 200 <= st < 300:
        E["floor"] = new_floor
    else:
        log("push refused: HTTP %s" % st)


# ---------------------------------------------------------------- backfill (never automatic: usage-metrics.sh --backfill)
class Fatal(Exception):
    def __init__(self, msg, code=1):
        Exception.__init__(self, msg)
        self.code = code


UNITS = {"USD": "USD", "tokens": "tokens", "s": "seconds"}
WHEN_RE = re.compile(r"^(\d{4}-\d\d-\d\d)(?:T(\d\d:\d\d)(:\d\d)?(\.\d+)?Z?)?$")


def parse_when(s):
    m = WHEN_RE.match(s or "")
    if not m:
        raise Fatal("time must be YYYY-MM-DD or an ISO time (UTC), got %r" % s, 2)
    t = parse_ts("%sT%s%s" % (m.group(1), m.group(2) or "00:00", m.group(3) or ":00"))
    if t is None:
        raise Fatal("time must be YYYY-MM-DD or an ISO time (UTC), got %r" % s, 2)
    return t


def docker(args, cwd=None, timeout=600):
    """-> (returncode, stdout, stderr) of `docker <args>`; Fatal(2) when docker is missing."""
    import subprocess
    try:
        r = subprocess.run(["docker"] + args, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except FileNotFoundError:
        raise Fatal("docker was not found on the PATH", 2)
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def discover_prometheus():
    """-> {name, image, volume, workdir, service}: the running Prometheus container (settings.metrics.prometheusContainer overrides)."""
    want = metrics_settings().get("prometheusContainer")
    if isinstance(want, str) and want:
        names = [want]
    else:
        rc, out, err = docker(["ps", "--format", "{{.Names}}\t{{.Image}}"])
        if rc != 0:
            raise Fatal("docker ps failed: %s" % err.strip()[:200], 2)
        names = []
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and re.match(r"^(?:[^/\s]+/)?prom/prometheus(?:[:@]|$)", parts[1].strip()):
                names.append(parts[0].strip())
        if not names:
            raise Fatal("No running Prometheus container (image prom/prometheus) found: set settings.metrics.prometheusContainer to its name.", 2)
        if len(names) > 1:
            raise Fatal("Several Prometheus containers are running (%s): set settings.metrics.prometheusContainer to the one to use." % ", ".join(sorted(names)), 2)
    rc, out, err = docker(["inspect", names[0]])
    try:
        info = json.loads(out)[0]
    except (ValueError, IndexError, TypeError):
        raise Fatal("docker inspect %s failed: %s" % (names[0], err.strip()[:200] or "no answer"), 2)
    if not (info.get("State") or {}).get("Running", True):
        raise Fatal("Container %s is not running." % names[0], 2)
    vol = ""
    for m in info.get("Mounts") or []:
        if m.get("Destination") == "/prometheus":
            vol = m.get("Name") or m.get("Source") or ""
    labels = (info.get("Config") or {}).get("Labels") or {}
    return {"name": names[0].lstrip("/"), "image": (info.get("Config") or {}).get("Image") or "prom/prometheus", "volume": vol,
            "workdir": labels.get("com.docker.compose.project.working_dir") or "", "service": labels.get("com.docker.compose.service") or ""}


def session_lines(state, sid):
    """The session's transcript lines of the kinds the parser uses, from all its files, in time order: [(time, is_sub, object)]."""
    out = []
    for p, e in state["files"].items():
        if e["session"] != sid or e.get("ignored"):
            continue
        is_sub = "/subagents/" in p
        last = 0.0
        try:
            with open(p, "rb") as f:
                for raw in f:
                    if not raw.endswith(b"\n"):
                        break
                    try:
                        o = json.loads(raw)
                    except ValueError:
                        continue
                    if not isinstance(o, dict) or o.get("type") not in ("assistant", "user", "system", "cost-state", "api-request"):
                        continue
                    t = parse_ts(o.get("timestamp")) if o.get("timestamp") else None
                    if t is None:
                        t = last
                    last = t
                    out.append((t, is_sub, o))
        except OSError:
            continue
    out.sort(key=lambda x: x[0])
    return out


def fingerprint(S):
    return (S["turns"], S["userMessages"], S["compactions"], S["apiErrors"], S["modelChanges"], len(S["workerDone"]), tuple(S["commits"]),
            tuple(S["locEdits"]), tuple(S["cs"]) if S["cs"] else None, sum(v["calls"] + v["errors"] for v in S["tools"].values()))


def sample_times(lines, lo, hi):
    """Multiples of 30 s from 60 s before each change of the session's values until 300 s after it, inside [lo, hi)."""
    S = new_session("x")
    events, prev = [], None
    for t, is_sub, o in lines:
        feed(S, o, is_sub, lambda cwd: True)
        fp = fingerprint(S)
        if fp != prev:
            events.append(t)
            prev = fp
    spans = []
    for t in events:
        a, b = t - 60, t + 300
        if spans and a <= spans[-1][1]:
            spans[-1][1] = max(spans[-1][1], b)
        else:
            spans.append([a, b])
    times = []
    for a, b in spans:
        k = int(-(-max(a, lo) // 30))
        while k * 30 <= b and k * 30 < hi:
            if k * 30 >= lo:
                times.append(k * 30)
            k += 1
    return times


def prom_name(name, unit, kind):
    base = name.replace(".", "_") + ("_" + UNITS.get(unit, unit) if unit else "")
    return base, base + "_total" if kind == "sum" else base


def esc_label(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def build_backfill(state, prom, since, until, task_filter, head_start, wts, scrape, constants):
    """-> (series {(family, kind, series name, labels tuple): [(t, v)]}, report dict)."""
    series, rep = {}, {"sessions": 0, "skipped": [], "unknownFirst": 0, "tasks": {}, "min": None, "max": None}
    pushed = state.get("pushed") or {}
    now = time.time()
    for sid, S0 in sorted(state["sessions"].items()):
        if not S0.get("kit"):
            continue
        hit = wt_match(wts, S0["cwd"]) if S0["cwd"] else None
        task = hit[0] if hit else ""
        if task_filter is not None and task != task_filter:
            continue
        if (parse_ts(S0["last"]) or 0) < since:
            continue
        P = pushed.get(sid) or {}
        if P.get("state") == "reset":
            rep["skipped"].append((sid, "its old counters reset"))
            continue
        end = min(until, head_start)
        if P.get("pos") is not None and P.get("state") != "history":
            if P.get("first"):
                end = min(end, P["first"])
            else:
                rep["unknownFirst"] += 1
        if P.get("cont"):
            cont = {"res": P["res"], "off": P["off"], "lab": P["lab"], "tlast": P.get("tlast") or {}}
        else:
            c = continuation(state, sid, prom, now)
            if c is None:
                rep["skipped"].append((sid, "its old counters reset"))
                continue
            cont = c
        lines = session_lines(state, sid)
        times = sample_times(lines, since, end)
        if not times:
            continue
        S = new_session(sid)
        PP = {"res": cont["res"], "off": cont["off"], "lab": cont["lab"], "vals": {}}
        i, vals, n_before = 0, {}, 0
        for ts in times:
            while i < len(lines) and lines[i][0] <= ts:
                feed(S, lines[i][2], lines[i][1], lambda cwd: True)
                i += 1
            if not S["first"]:
                continue
            S["task"] = task
            res = resource_of(S, PP, constants, task)
            rl = {k.replace(".", "_"): v for k, v in res.items()}
            rl.update(scrape)
            for name, unit, kind, attrs, value, base in session_points(S, PP):
                if base and ts <= (cont["tlast"] or {}).get(base, 0):
                    continue
                v = float(value) + (PP["off"].get(base, 0) if base else 0)
                key = name + "|" + "|".join("%s=%s" % kv for kv in sorted(attrs.items()))
                if kind == "sum":
                    v = max(v, vals.get(key, 0.0))
                vals[key] = v
                fam, sname = prom_name(name, unit, kind)
                lab = dict(rl)
                lab.update({k.replace(".", "_"): x for k, x in attrs.items() if x not in (None, "")})
                series.setdefault((fam, kind, sname, tuple(sorted(lab.items()))), []).append((ts, v))
        if S["first"]:
            rep["sessions"] += 1
            tk = rep["tasks"].setdefault(task, {"sessions": 0, "cost": 0.0, "tokens": 0})
            tk["sessions"] += 1
            tk["cost"] += sum(vals[k] for k in vals if k.startswith("claude_code.cost.usage|"))
            tk["tokens"] += sum(vals[k] for k in vals if k.startswith("claude_code.token.usage|"))
            rep["min"] = min(rep["min"] or times[0], times[0])
            rep["max"] = max(rep["max"] or times[-1], times[-1])
    return series, rep


def write_om(series, path):
    by_fam = {}
    for (fam, kind, sname, lab), pts in series.items():
        by_fam.setdefault((fam, kind), []).append((sname, lab, pts))
    n = 0
    with open(path, "w") as f:
        for (fam, kind), items in sorted(by_fam.items()):
            f.write("# TYPE %s %s\n" % (fam, "counter" if kind == "sum" else "gauge"))
            for sname, lab, pts in sorted(items):
                ls = ",".join('%s="%s"' % (k, esc_label(v)) for k, v in lab)
                for t, v in pts:
                    f.write("%s{%s} %s %d\n" % (sname, ls, repr(float(v)), t))
                    n += 1
        f.write("# EOF\n")
    return n


def wait_ready(prom, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try:
            st, _ = http_json("%s/-/ready" % prom.rstrip("/"), timeout=3)
            if st == 200:
                return True
        except Down:
            pass
        time.sleep(1)
    return False


def backfill(args):
    opts = {"since": None, "until": None, "task": None, "dry": False, "yes": False}
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--since", "--until", "--task") and i + 1 < len(args):
            opts[a[2:]] = args[i + 1]
            i += 1
        elif a == "--dry-run":
            opts["dry"] = True
        elif a == "--yes":
            opts["yes"] = True
        else:
            raise Fatal("usage: usage-metrics.sh --backfill --since <ISO time|YYYY-MM-DD> [--until <ISO time>] [--task <t>] [--dry-run] [--yes]", 2)
        i += 1
    if not opts["since"]:
        raise Fatal("--backfill needs --since <ISO time|YYYY-MM-DD>", 2)
    since = parse_when(opts["since"])
    until = parse_when(opts["until"]) if opts["until"] else time.time()
    otlp, prom, allow = push_settings()
    if not allow and (urllib.parse.urlparse(prom).hostname or "") not in LOOPBACK:
        raise Fatal("prometheusUrl %s is not on this machine and settings.metrics.allowRemote is not true" % prom, 2)
    dock = discover_prometheus()
    try:
        st, js = http_json("%s/api/v1/status/tsdb" % prom.rstrip("/"))
    except Down:
        st, js = None, None
    try:
        head_ms = float(((js or {}).get("data") or {}).get("headStats", {}).get("minTime"))
    except (TypeError, ValueError):
        raise Fatal("Prometheus did not answer %s/api/v1/status/tsdb: it must be running to find the start of its head block." % prom, 1)
    head_start = head_ms / 1000.0
    state = load_state()
    if not state["sessions"]:
        raise Fatal("The store has no sessions: run usage-metrics.sh --once first.", 2)
    wts = load_worktrees()
    scratch = {"constants": json.loads(json.dumps(state.get("constants") or {"day": "", "labels": {}}))}
    scratch["constants"]["day"] = ""
    try:
        constants = refresh_constants(scratch, prom)
        found = prom_series(prom, '{__name__=~"claude_code_.+"}', time.time() - 90 * 86400)
    except Down:
        raise Fatal("Prometheus stopped answering while reading its labels.", 1)
    scrape = {k: v for k, v in (found[-1].items() if found else []) if k in ("job", "instance")}
    try:
        series, rep = build_backfill(state, prom, since, until, opts["task"], head_start, wts, scrape, constants)
    except Down:
        raise Fatal("Prometheus stopped answering while reading the old series of a session.", 1)
    os.makedirs(MDIR, exist_ok=True)
    ts_name = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    om = os.path.join(MDIR, "backfill-%s.om" % ts_name)
    nsamp = write_om(series, om)
    fmt = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else "-"
    print("Backfill file: %s" % om)
    print("Window: from %s to %s (head block of Prometheus starts %s; each session also ends before its first live push)" % (fmt(since), fmt(min(until, head_start)), fmt(head_start)))
    print("Series: %d  samples: %d  sessions: %d  range: %s .. %s" % (len(series), nsamp, rep["sessions"], fmt(rep["min"]), fmt(rep["max"])))
    for t, v in sorted(rep["tasks"].items()):
        print("  task %-20s %3d sessions  cost $%.4f  tokens %d" % (t or "(none)", v["sessions"], v["cost"], v["tokens"]))
    for sid, why in rep["skipped"]:
        print("  skipped session %s: %s" % (sid, why))
    if rep["unknownFirst"]:
        print("  note: %d sessions were pushed live but their first push time is unknown; only the head block limits them" % rep["unknownFirst"])
    if not scrape:
        print("  note: no job/instance labels found in Prometheus; the samples carry none")
    print("Prometheus container: %s (volume %s, compose %s service %s)" % (dock["name"], dock["volume"] or "?", dock["workdir"] or "?", dock["service"] or "?"))
    if nsamp == 0:
        print("Nothing to import.")
        return 0
    c = dock["name"]
    if opts["dry"]:
        rc, _, err = docker(["cp", om, "%s:/tmp/%s" % (c, os.path.basename(om))])
        if rc != 0:
            raise Fatal("docker cp failed: %s" % err.strip()[:200])
        rc, out, err = docker(["exec", c, "sh", "-c", "promtool check metrics < /tmp/%s" % os.path.basename(om)])
        docker(["exec", c, "rm", "-f", "/tmp/" + os.path.basename(om)])
        lint = [l for l in (out + err).splitlines() if l.strip() and "no help text" not in l]
        if lint:
            print("promtool check metrics reported problems:")
            for l in lint[:20]:
                print("  " + l)
            return 1
        print("promtool check metrics: ok (only 'no help text' lints). Dry run: nothing was written to Prometheus.")
        return 0
    if not (dock["workdir"] and dock["service"] and dock["volume"]):
        raise Fatal("The container has no compose labels or no /prometheus volume: this tool cannot stop and back it up.", 2)
    backup = os.path.join(os.path.expanduser("~"), "prometheus-backups", "prometheus-data-%s.tgz" % ts_name)
    print("It will: stop %s (docker compose stop %s in %s), back up the volume to %s, start it again, wait until it is ready, build blocks with "
          "promtool in the container and move them into /prometheus. Prometheus is down for about a minute." % (c, dock["service"], dock["workdir"], backup))
    if not opts["yes"]:
        raise Fatal("add --yes after the user agreed", 2)
    stopped = [False]

    def restart():
        if stopped[0]:
            docker(["compose", "start", dock["service"]], cwd=dock["workdir"])
            stopped[0] = False

    try:
        os.makedirs(os.path.dirname(backup), exist_ok=True)
        rc, _, err = docker(["compose", "stop", dock["service"]], cwd=dock["workdir"])
        if rc != 0:
            raise Fatal("docker compose stop failed: %s" % err.strip()[:200])
        stopped[0] = True
        rc, _, err = docker(["run", "--rm", "--user", "root", "--entrypoint", "tar", "-v", "%s:/src:ro" % dock["volume"], "-v", "%s:/dst" % os.path.dirname(backup),
                             dock["image"], "czf", "/dst/" + os.path.basename(backup), "-C", "/src", "."])
        listing = ""
        if rc == 0:
            import subprocess
            r = subprocess.run(["tar", "tzf", backup], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            listing = r.stdout.decode("utf-8", "replace") if r.returncode == 0 else ""
        if rc != 0 or not listing.strip():
            raise Fatal("The backup of the volume failed (%s); nothing was imported." % (err.strip()[:200] or "empty archive"))
        rc, _, err = docker(["compose", "start", dock["service"]], cwd=dock["workdir"])
        if rc != 0:
            raise Fatal("docker compose start failed: %s" % err.strip()[:200])
        stopped[0] = False
        print("Backup: %s (%d entries)" % (backup, len(listing.splitlines())))
        if not wait_ready(prom, int(os.environ.get("ORCA_ROLES_BACKFILL_WAIT", "90"))):
            raise Fatal("Prometheus did not become ready after the restart; nothing was imported.")
    except Fatal:
        restart()
        raise
    name = os.path.basename(om)
    for step, args2 in (("copy the file", ["cp", om, "%s:/tmp/%s" % (c, name)]),
                        ("build the blocks", ["exec", c, "sh", "-c", "rm -rf /tmp/import-blocks && mkdir /tmp/import-blocks && promtool tsdb create-blocks-from openmetrics /tmp/%s /tmp/import-blocks" % name])):
        rc, _, err = docker(args2)
        if rc != 0:
            raise Fatal("Could not %s: %s. Nothing was moved into /prometheus." % (step, err.strip()[:300]))
    rc, out, _ = docker(["exec", c, "ls", "/tmp/import-blocks"])
    ulids = out.split()
    rc, _, err = docker(["exec", c, "sh", "-c", "mkdir /prometheus/import-staging && cp -r /tmp/import-blocks/* /prometheus/import-staging/ && "
                         "for b in /prometheus/import-staging/*; do mv \"$b\" /prometheus/; done && rmdir /prometheus/import-staging"])
    if rc != 0:
        raise Fatal("Could not move the blocks into /prometheus: %s. Check %s for a leftover import-staging folder (it is ignored by Prometheus)." % (err.strip()[:300], dock["volume"]))
    print("Blocks moved into /prometheus: %s" % " ".join(ulids))
    tasks = [t for t in rep["tasks"] if t]
    if tasks:
        q = 'sum by (task)(max_over_time(claude_code_cost_usage_USD_total{task=~"%s"}[%dd]))' % ("|".join(re.escape(t) for t in tasks), max(1, int((time.time() - since) // 86400) + 2))
        end = time.time() + int(os.environ.get("ORCA_ROLES_BACKFILL_WAIT", "90"))
        got = {}
        while time.time() < end:
            try:
                got = {r["metric"].get("task"): float(r["value"][1]) for r in prom_vector(prom, q)}
            except (Down, KeyError, ValueError):
                got = {}
            if all(got.get(t, 0) >= rep["tasks"][t]["cost"] * 0.99 for t in tasks):
                break
            time.sleep(3)
        for t in tasks:
            print("  Prometheus now: task %s cost $%.4f (file: $%.4f)" % (t, got.get(t, 0.0), rep["tasks"][t]["cost"]))
    print("Undo: docker compose stop %s; restore the backup into the volume (docker run --rm --user root --entrypoint sh -v %s:/p -v %s:/b:ro %s "
          "-c 'cd /p && rm -rf /p/* && tar xzf /b/%s -C /p'); docker compose start %s   (run in %s)"
          % (dock["service"], dock["volume"], os.path.dirname(backup), dock["image"], os.path.basename(backup), dock["service"], dock["workdir"]))
    return 0


def prune_pushed(state, keep_days):
    """Drops the pushed values of a session whose transcripts are all gone and that has not changed for retentionDays."""
    pushed = state.get("pushed") or {}
    limit = time.time() - keep_days * 86400
    for sid in [k for k, P in pushed.items() if k not in state["sessions"] and (P.get("seen") or 0) < limit]:
        del pushed[sid]


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
        try:
            push(state)
        except Exception as ex:   # a push problem never fails the pass
            log("push failed: %s: %s" % (type(ex).__name__, ex))
        try:
            push_events(state, wts)
        except Exception as ex:
            log("events push failed: %s: %s" % (type(ex).__name__, ex))
        prune_pushed(state, retention_days())
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
    ev_counts = {}
    try:
        with open(os.path.join(MDIR, "events.jsonl"), "rb") as f:
            raw_ev = f.read()
    except OSError:
        raw_ev = b""
    evl = []
    for ln in raw_ev.splitlines():
        try:
            eo = json.loads(ln.decode("utf-8", "replace"))
        except ValueError:
            continue
        if isinstance(eo, dict) and (since is None or str(eo.get("ts") or "")[:10] >= since):
            evl.append(eo)
    tally_events(evl, load_worktrees(), ev_counts)
    events = {}
    for key, n in ev_counts.items():
        t, _, ev, role = key.split(SEP)
        if task is not None and t != task:
            continue
        d = events.setdefault(t, {})
        d[ev] = d.get(ev, 0) + n
    res = {"task": task, "since": since, "events": {k: dict(sorted(v.items())) for k, v in sorted(events.items())}, "total": rnd(total), "byTask": {k: rnd(v) for k, v in sorted(by_task.items())},
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
    if res["events"]:
        print("kit events and dispatch outcomes by task:")
        for k, v in res["events"].items():
            print("  %-28s %s" % (k or "(none)", "  ".join("%s %d" % kv for kv in v.items())))
    return 0


def main(argv):
    if len(argv) >= 1 and argv[0] == "--once" and len(argv) == 1:
        return once()
    if len(argv) >= 1 and argv[0] == "--report":
        return report(argv[1:])
    if len(argv) >= 1 and argv[0] == "--backfill":
        try:
            return backfill(argv[1:])
        except Fatal as ex:
            print("usage-metrics.sh: %s" % ex, file=sys.stderr)
            return ex.code
    print("usage: usage-metrics.sh --once | --report [--task <t>] [--since <YYYY-MM-DD>] [--json] | --backfill --since <time> [--until <time>] [--task <t>] [--dry-run] [--yes]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
