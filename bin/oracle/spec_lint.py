#!/usr/bin/env python3
"""Task spec linter. Usage: spec_lint.py --file spec.md | --task <task_id> [--json]
       spec_lint.py --batch-spec [--require-acceptance] [--file spec.md] [--json]
Task mode requires Target, Change, Constraints, Ownership and an acceptance section headed exactly `## Acceptance command`
with at least one allowed command (see allow.py). Accepts English headings for the other four fields (some Spanish synonyms too).
Batch mode checks a Planner's spec: fenced blocks and `file:line` references outside the acceptance section, and the section's format.
Exits 1 if something is reported. Changes nothing."""
import json
import os
import posixpath
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
FENCE = re.compile(r'^ {0,3}(?:```|~~~)')
ATX = re.compile(r'^ {0,3}#{1,6}(?:[ \t]|$)')
EXACT_ACCEPTANCE = re.compile(r'^## Acceptance command[ \t]*$')
BOLD_LINE = re.compile(r'^ {0,3}\*\*.+\*\*:?[ \t]*$')
RUNNER_DECL = re.compile(r'^ *Runner files edited:(.*)$')
RUNNER_OUTSIDE = re.compile(r'^[ \t]*(?:[-*+][ \t]+)?(?:\*\*)?runner files edited', re.I)
LITERAL = re.compile(r'<!-- spec-lint: literal -->[ \t]*$')
LINE_REF = re.compile(r'([\w./-]*\.[A-Za-z][A-Za-z0-9]{0,9})(?::\d+(?:-\d+|:\d+)?|#[Ll]\d+)')


def sections(spec):
    marks = [(m.start(), m.end(), (m.group(1) or m.group(2) or '').strip().lower()) for m in HEAD.finditer(spec)]
    out = []
    for i, (s, e, name) in enumerate(marks):
        out.append((name, spec[e:marks[i + 1][0] if i + 1 < len(marks) else len(spec)]))
    return out


def fence_state(lines):
    """(inside, openings) for the spec's lines: inside[i] is True for a line inside a fenced block, openings lists the 0-based
    lines that open one (a fence line toggles whatever its marker)."""
    inside = []
    openings = []
    open_ = False
    for l in lines:
        if FENCE.match(l):
            if not open_:
                openings.append(len(inside))
            open_ = not open_
            inside.append(False)
        else:
            inside.append(open_)
    return inside, openings


def section_end(lines, inside, start):
    """The 0-based index of the first line after the section that starts at `start`, or len(lines)."""
    for j in range(start + 1, len(lines)):
        if not inside[j] and ATX.match(lines[j]):
            return j
    return len(lines)


def clean_item(item):
    """One item of a `Runner files edited:` line: no surrounding whitespace or backticks, normalized as a path."""
    p = item.strip().strip('`').strip()
    return posixpath.normpath(p) if p else ''


def acceptance_section(spec):
    """The spec's acceptance section: body (str or None), line (int or None), count, inexact (near-miss line numbers) and
    runner_files (paths declared on `Runner files edited:` lines of the body, outside fenced blocks)."""
    lines = spec.splitlines()
    inside, _ = fence_state(lines)
    exact = [i for i, l in enumerate(lines) if not inside[i] and EXACT_ACCEPTANCE.match(l)]
    body = None
    end = 0
    if exact:
        end = section_end(lines, inside, exact[0])
        body = '\n'.join(lines[exact[0] + 1:end])
    inexact = [i + 1 for i, l in enumerate(lines)
               if not inside[i] and not EXACT_ACCEPTANCE.match(l) and (ATX.match(l) or BOLD_LINE.match(l))
               and 'acceptance command' in l.lower()]
    runner = []
    if exact:
        for i in range(exact[0] + 1, end):
            if inside[i]:
                continue
            m = RUNNER_DECL.match(lines[i])
            if not m:
                continue
            for item in m.group(1).split(','):
                p = clean_item(item)
                if p and p not in runner:
                    runner.append(p)
    return dict(body=body, line=exact[0] + 1 if exact else None, count=len(exact), inexact=inexact, runner_files=runner)


def lint(spec):
    secs = sections(spec)
    acc = acceptance_section(spec)
    found = {}
    for field, rx in FIELDS.items():
        if field == 'Observable acceptance':
            continue
        for name, body in secs:
            if re.search(r'^(?:%s)\b' % rx, name):
                found[field] = body
                break
    if acc['count']:
        found['Observable acceptance'] = acc['body']
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


def word_around(text, start, end):
    a = start
    while a > 0 and not text[a - 1].isspace():
        a -= 1
    b = end
    while b < len(text) and not text[b].isspace():
        b += 1
    return text[a:b]


def has_line_ref(line):
    """A path-like word ending in an extension and followed by :<line> (or #L<line>), outside a URL."""
    for m in LINE_REF.finditer(line):
        if '://' not in word_around(line, m.start(), m.end()):
            return True
    return False


def batch_lint(spec, require_acceptance=False):
    """Lints a Planner's batch spec: code blocks and file:line references outside the acceptance section, and the section's format."""
    lines = spec.splitlines()
    inside, openings = fence_state(lines)
    acc = acceptance_section(spec)
    exact = [i for i, l in enumerate(lines) if not inside[i] and EXACT_ACCEPTANCE.match(l)]
    if exact:
        head = exact[0]
        end = section_end(lines, inside, head)
    else:
        head = None
        end = 0

    def in_section(i):
        return head is not None and head <= i < end

    def text_of(i):
        return lines[i].strip()[:120]

    found = []
    if require_acceptance and not exact:
        found.append((-1, dict(kind='acceptance_missing', line=None, text='')))
    for i in openings:
        if not in_section(i):
            found.append((i, dict(kind='code_block', line=i + 1, text=text_of(i))))
    literal_lines = 0
    for i, l in enumerate(lines):
        if in_section(i):
            continue
        if LITERAL.search(l):
            literal_lines += 1
        elif has_line_ref(l):
            found.append((i, dict(kind='line_ref', line=i + 1, text=text_of(i))))
    if exact:
        for i in exact[1:]:
            found.append((i, dict(kind='acceptance_duplicate', line=i + 1, text=text_of(i))))
        checks = [(c, check_command(c)) for c in command_lines(acc['body'] or '')]
        if not any(ok for _, (ok, _) in checks):
            reasons = [r for _, (ok, r) in checks if not ok]
            found.append((head, dict(kind='acceptance_no_command', line=head + 1,
                                     text=(lines[head].strip() + ' — ' + ('; '.join(reasons) if reasons else 'no command'))[:120])))
    for i in acc['inexact']:
        found.append((i - 1, dict(kind='acceptance_heading_inexact', line=i, text=text_of(i - 1))))
    for i, l in enumerate(lines):
        if inside[i]:
            continue
        if not in_section(i):
            if RUNNER_OUTSIDE.match(l):
                found.append((i, dict(kind='runner_files_outside', line=i + 1, text=text_of(i))))
            continue
        if 'runner files edited' not in l.lower():
            continue
        m = RUNNER_DECL.match(l)
        paths = []
        bad = m is None
        if m:
            for item in m.group(1).split(','):
                p = item.strip().strip('`').strip()
                if not p:
                    continue
                if p.startswith('/') or p.startswith('~') or '..' in p.split('/'):
                    bad = True
                paths.append(p)
            bad = bad or not paths
        if bad:
            found.append((i, dict(kind='runner_files_invalid', line=i + 1, text=text_of(i))))
    found.sort(key=lambda t: t[0])
    problems = [p for _, p in found]
    return dict(ok=not problems, problems=problems, literal_lines=literal_lines)


def _orca(*args):
    r = subprocess.run(['orca', 'orchestration'] + list(args) + ['--json', '--full'], capture_output=True, text=True)
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
    res = batch_lint(spec, '--require-acceptance' in a) if '--batch-spec' in a else lint(spec)
    print(json.dumps(res, ensure_ascii=False, indent=None if '--json' in a else 1))
    sys.exit(0 if res['ok'] else 1)
