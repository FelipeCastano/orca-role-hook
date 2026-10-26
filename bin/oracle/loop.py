#!/usr/bin/env python3
"""loop: one read-only coordinator cycle, so the Planner is only woken when something needs it. Usage:
  loop.py [--run ID ...] [--since-hours 48] [--force] [--no-verify] [--timeout 600] [--max-load 0.8] [--wait-max 300]
For each Run it reads the tasks (task-list), the workers (worker-list) and the messages (inbox, which marks nothing as read):
- unread question / escalation / failed messages -> wake;
- a task completed with outcome succeeded -> verify_task.py in its worktree (unless a verify.json exists, or with --force);
  pass / pass_flaky -> quiet; fail, cheat, command_not_allowed, env_not_runnable, no_acceptance_command, no_worktree, verify_error -> wake;
- what a full loop would do (ack, worker-release, verify with --no-verify) is only listed in `would_do`, never executed.
It never acks, releases, sends or writes to Orca. It runs commands only through verify_task.py (allowlisted, in the task's worktree)
and never with --no-verify. Output: JSON {ts, dry_run: true, wake, reasons, runs}. Exit 0 on a completed cycle."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
WAKE_MSG = {'question', 'escalation', 'failed'}
QUIET = {'pass', 'pass_flaky'}


def orca_cmd():
    """'orca', or $ORCA_CLI_COMMAND when 'orca' is not on the PATH (the same rule as the kit's shim)."""
    alt = os.environ.get('ORCA_CLI_COMMAND') or ''
    if shutil.which('orca') is None and alt and shutil.which(alt):
        return alt
    return 'orca'


def run_orca(args):
    try:
        return subprocess.run([orca_cmd()] + list(args), capture_output=True, text=True)
    except OSError:
        return None


def orca(*a):
    """result of `orca orchestration <a> --json`, or None if it failed."""
    r = run_orca(['orchestration'] + list(a) + ['--json'])
    if r is None:
        return None
    try:
        d = json.loads(r.stdout)
    except ValueError:
        return None
    return d.get('result') if d.get('ok') else None


def wt_path(wid):
    return wid.split('::', 1)[1].split('@@')[0] if wid and '::' in wid else None


def wt_from_terminal(handle):
    """A worker without a supervised workspace: worker-list has none, but its terminal keeps the worktreeId."""
    if not handle:
        return None
    r = run_orca(['terminal', 'show', '--terminal', handle, '--json'])
    if r is None:
        return None
    try:
        t = json.loads(r.stdout)['result']['terminal']
    except (ValueError, KeyError, TypeError):
        return None
    return wt_path(t.get('worktreeId'))


def verify_json(task):
    root = os.environ.get('ORCA_ROLES_ORACLE_OUT') or os.path.join(
        os.environ.get('XDG_CACHE_HOME') or os.path.join(os.path.expanduser('~'), '.cache'), 'orca-roles', 'oracle')
    p = os.path.join(root, re.sub(r'[^A-Za-z0-9_.-]', '_', task), 'verify.json')
    try:
        with open(p) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def status_of(d):
    return 'cheat' if d.get('cheat') else (d.get('status') or 'verify_error')


def pick_runs(args, reasons):
    if args.run:
        return args.run
    res = orca('run-list')
    if res is None:
        reasons.append('orca run-list failed (is Orca running?)')
        return []
    lim = (datetime.now(timezone.utc) - timedelta(hours=args.since_hours)).strftime('%Y-%m-%dT%H:%M:%SZ')
    return [r['id'] for r in res.get('runs', []) if (r.get('updated_at') or '') >= lim]


def loop_run(run, args, inbox):
    out = dict(run=run, verified=[], messages=[], would_do=[], reasons=[])
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=args.since_hours)).strftime('%Y-%m-%dT%H:%M:%S')
    tasks = (orca('task-list', '--run', run) or {}).get('tasks', [])
    workers = (orca('worker-list', '--run', run, '--limit', '100') or {}).get('workers', [])
    wk = {w.get('taskId'): w for w in workers}
    for m in inbox:
        if m.get('run_id') == run and m.get('type') in WAKE_MSG and str(m.get('read')).lower() in ('0', 'false', 'none'):
            out['messages'].append(dict(id=m.get('id'), type=m['type'], subject=(m.get('subject') or '')[:80]))
            out['reasons'].append('unread %s message: %s' % (m['type'], m.get('id')))
    for t in tasks:
        if t.get('status') != 'completed':
            continue
        try:
            res = json.loads(t.get('result') or '{}')
        except ValueError:
            res = {}
        if not isinstance(res, dict) or res.get('outcome') != 'succeeded':
            continue
        tid = t['id']
        w = wk.get(tid)
        if (t.get('completed_at') or '') < cutoff:
            continue
        prev = verify_json(tid)
        if prev and not args.force:   # not run again, but a cached result that is not green still wakes
            st = status_of(prev)
            out['verified'].append(dict(task=tid, status=st, cached=True))
            if st not in QUIET:
                out['reasons'].append('%s: verification %s (cached)' % (tid, st))
            continue
        ws = ((w or {}).get('projection') or {}).get('workspace') or {}
        wt = wt_path(ws.get('id')) or wt_from_terminal((w or {}).get('agentTerminalHandle'))
        if not wt or not os.path.isdir(wt):
            out['verified'].append(dict(task=tid, status='no_worktree'))
            out['reasons'].append('%s: no worktree to verify (path missing: deleted, or a worker without a terminal)' % tid)
            continue
        if args.no_verify:
            out['would_do'].append('verify %s in %s' % (tid, os.path.basename(wt)))
            continue
        cmd = [sys.executable, os.path.join(HERE, 'verify_task.py'), '--worktree', wt, '--task', tid, '--run', run,
               '--timeout', str(args.timeout)]
        if args.max_load is not None:
            cmd += ['--max-load', str(args.max_load)]
        if args.wait_max is not None:
            cmd += ['--wait-max', str(args.wait_max)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        try:
            d = json.loads(r.stdout)
            st = status_of(d)
        except (ValueError, AttributeError):
            out['verified'].append(dict(task=tid, status='verify_error'))
            out['reasons'].append('%s: verify_task.py failed: %s' % (tid, (r.stderr or '').strip()[-120:]))
            continue
        out['verified'].append(dict(task=tid, status=st, seconds=d.get('duration_s'), flaky_isolated=d.get('flaky_isolated', 0)))
        if st not in QUIET:
            out['reasons'].append('%s: verification %s' % (tid, st))
        elif w and w.get('terminalState') in ('reclaimable', 'retained') and w.get('dispatchId'):
            out['would_do'].append('worker-release --dispatch %s' % w['dispatchId'])
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog='loop.py')
    ap.add_argument('--run', action='append')
    ap.add_argument('--since-hours', type=float, default=48)
    ap.add_argument('--force', action='store_true')
    ap.add_argument('--no-verify', action='store_true')
    ap.add_argument('--timeout', type=int, default=600)
    ap.add_argument('--max-load', type=float)
    ap.add_argument('--wait-max', type=int)
    args = ap.parse_args(argv)
    top = []
    inb = orca('inbox', '--limit', '500')
    if inb is None:
        top.append('orca inbox failed (is Orca running?)')
    inbox = (inb or {}).get('messages', [])
    runs = [loop_run(r, args, inbox) for r in pick_runs(args, top)]
    reasons = top + [x for r in runs for x in r['reasons']]
    print(json.dumps(dict(ts=time.strftime('%Y-%m-%dT%H:%M:%S'), dry_run=True, wake=bool(reasons), reasons=reasons, runs=runs), indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
