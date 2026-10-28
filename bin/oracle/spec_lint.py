#!/usr/bin/env python3
"""Task spec linter. Usage: spec_lint.py --file spec.md | --task <task_id> [--json]
Requires: Target, Change, Constraints, Ownership and an acceptance section with at least one allowed command (see allow.py).
Accepts English headings (some Spanish synonyms too). Exits 1 if something is missing. Changes nothing."""
import json
import os
import re
import subprocess
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from allow import command_lines, check_command  # noqa: E402

FIELDS = {
    'Target': r'target|objetivo|destino|qué hay que hacer|que hay que hacer|goal',
    'Change': r'change|cambio|qué cambiar|que cambiar|do|hazlo|cómo|implementaci[oó]n',
    'Constraints': r'constraints?|restricciones|prohibido|no hagas|l[ií]mites|standing rules|rules',
    'Ownership': r'ownership|propiedad|ficheros? (?:que )?(?:puedes|posees|tocas|tuyos)|alcance|files? you own|scope',
    'Observable acceptance': r'acceptance command|observable acceptance|criterio de terminado|cu[aá]ndo est[aá] hecho|criterios? de aceptaci[oó]n|aceptaci[oó]n|acceptance|definition of done|how (?:this is|work is) judged',
}
HEAD = re.compile(r'(?m)^[ \t]{0,3}(?:#{1,4}[ \t]*|\*\*[ \t]*)([^\n*#:]{2,60}?)[ \t]*(?:\*\*)?[ \t]*:?[ \t]*$|^[ \t]{0,3}(?:#{1,4}[ \t]*|\*\*[ \t]*)([^\n*#:]{2,60}?)(?::|\*\*)')


def sections(spec):
    marks = [(m.start(), m.end(), (m.group(1) or m.group(2) or '').strip().lower()) for m in HEAD.finditer(spec)]
    out = []
    for i, (s, e, name) in enumerate(marks):
        out.append((name, spec[e:marks[i + 1][0] if i + 1 < len(marks) else len(spec)]))
    return out


def lint(spec):
    secs = sections(spec)
    found = {}
    for field, rx in FIELDS.items():
        for name, body in secs:
            if re.search(r'^(?:%s)\b' % rx, name) or (re.search(r'\b(?:%s)\b' % rx, name) and field == 'Observable acceptance'):
                found[field] = body
                break
    missing = [f for f in FIELDS if f not in found]
    acc_cmds = []
    if 'Observable acceptance' in found:
        acc_cmds = command_lines(found['Observable acceptance'])
    checks = [(c, check_command(c)) for c in acc_cmds]
    allowed = [c for c, (ok, _) in checks if ok]
    problems = ['missing %s' % f for f in missing]
    if 'Observable acceptance' in found and not allowed:
        why = ' (%d candidates rejected: %s)' % (len(checks), '; '.join(r for _, (ok, r) in checks if not ok)[:160]) if checks else ''
        problems.append('the acceptance section has no allowed executable command' + why)
    return dict(ok=not problems, missing=missing, problems=problems, acceptance_commands=len(allowed), rejected_commands=len(checks) - len(allowed))


def _orca(*args):
    r = subprocess.run(['orca', 'orchestration'] + list(args) + ['--json'], capture_output=True, text=True)
    try:
        d = json.loads(r.stdout)
    except Exception:
        raise SystemExit('orca %s did not return JSON: %s' % (args[0], r.stderr[:200]))
    if d.get('ok') is False:
        raise SystemExit('orca %s: %s: %s' % (args[0], (d.get('error') or {}).get('code'), str((d.get('error') or {}).get('message'))[:160]))
    return d.get('result', d)


def load_task_spec(task_id, run=None):
    """The task's spec, from the given Run or else from the Runs, newest first."""
    runs = [run] if run else [r['id'] for r in sorted(_orca('run-list').get('runs', []), key=lambda r: r.get('created_at') or '', reverse=True)]
    for rid in runs:
        for t in _orca('task-list', '--run', rid).get('tasks', []):
            if t.get('id') == task_id or t.get('task_id') == task_id:
                return t.get('spec') or ''
    raise SystemExit('task %s not found in %d run(s)' % (task_id, len(runs)))


if __name__ == '__main__':
    a = sys.argv[1:]
    if '--file' in a:
        spec = open(a[a.index('--file') + 1]).read()
    elif '--task' in a:
        spec = load_task_spec(a[a.index('--task') + 1], a[a.index('--run') + 1] if '--run' in a else None)
    else:
        spec = sys.stdin.read()
    res = lint(spec)
    print(json.dumps(res, ensure_ascii=False, indent=None if '--json' in a else 1))
    sys.exit(0 if res['ok'] else 1)
