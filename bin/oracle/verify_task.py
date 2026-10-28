#!/usr/bin/env python3
"""verify-task: "done" = the oracle passes. Usage:
  verify_task.py --worktree <path> (--spec-file f | --task <id>) [--base <ref>] [--timeout 600] [--retries 1]
                 [--max-load 0.8] [--wait-max 300] [--no-wait] [--dry-run] [--agent A --model M] [--config-sha S]
1) takes the acceptance command from the task spec (never from the worker) and runs only what allow.py permits, in the worktree;
2) checks test integrity of the whole worktree (untracked files included) against the base: deleted test files, added skip/xfail/.only, weakened tests, and changes to the runner's own configuration;
3) writes verify.json to $ORCA_ROLES_ORACLE_OUT (default ${XDG_CACHE_HOME:-~/.cache}/orca-roles/oracle)/<task>/, never inside the repo.
Statuses: pass, pass_flaky, fail, no_acceptance_command, command_not_allowed, env_not_runnable, dry_run.
Exit 0 only on pass (or pass_flaky) and no cheat."""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from allow import command_lines, check_command, split_and  # noqa: E402
from spec_lint import sections, FIELDS, load_task_spec  # noqa: E402

TEST_PATH = re.compile(r'(^|/)(tests?|__tests__|spec|e2e)/|(\.|_)(test|spec)\.[a-z]+$|(^|/)test_[^/]+\.py$', re.I)
SKIP = re.compile(r'@pytest\.mark\.(?:skip|xfail)|pytest\.(?:skip|xfail)\(|\b(?:it|test|describe)\.(?:skip|todo)\(|\b(?:xit|xdescribe|xtest)\(|t\.Skip\(|#\[ignore\]|\.only\(', re.I)
SECRET = re.compile(r'(sk-[A-Za-z0-9_\-]{16,}|eyJ[A-Za-z0-9_\-]{20,}|gh[pousr]_\w{20,}|Bearer\s+\S+)')


def git(wt, *a):
    return subprocess.run(['git', '-c', 'core.quotePath=false', '-C', wt] + list(a), capture_output=True, text=True, errors='replace')


def git_env(wt, env, *a):
    return subprocess.run(['git', '-c', 'core.quotePath=false', '-C', wt] + list(a), capture_output=True, text=True, errors='replace', env=env)


def git_bytes(wt, *a, **kw):
    return subprocess.run(['git', '-c', 'core.quotePath=false', '-C', wt] + list(a), capture_output=True, **kw)


def pick_base(wt, given):
    if given:
        return given
    for ref in ('origin/HEAD', 'origin/main', 'origin/master', 'origin/develop', 'main', 'master', 'develop'):
        if git(wt, 'rev-parse', '--verify', '-q', ref).returncode == 0:
            mb = git(wt, 'merge-base', 'HEAD', ref)
            if mb.returncode == 0 and mb.stdout.strip():
                return mb.stdout.strip()
    return None


def stem_of(path):
    name = os.path.basename(path)
    stem = re.sub(r'(\.(test|spec))?\.[a-z]+$', '', name)
    return re.sub(r'^test_', '', stem)


def subject_also_deleted(all_deleted, test_path):
    """Evidence of a legitimate refactor: a non-test file with the same base name was deleted too."""
    st = stem_of(test_path)
    return any(stem_of(p) == st and p != test_path and not TEST_PATH.search(p) for p in all_deleted)


CONFIG_NAMES = {'pytest.ini', 'pyproject.toml', 'setup.cfg', 'tox.ini', 'noxfile.py', 'conftest.py',
                'Makefile', 'makefile', 'GNUmakefile', 'package.json'}
SCRIPT_REF = re.compile(r'(?:npm run(?:-script)?|pnpm(?: run)?|yarn(?: run)?)\s+([A-Za-z0-9_:.\-]+)')
NPM_TEST_REF = re.compile(r'npm (?:test|t)\b')
SH_REF = (re.compile(r'(?:^|[\s;&|(])(?:bash|sh)(?:\s+-[A-Za-z]+)*\s+([\w./\-]+\.sh)\b'),
          re.compile(r'(?:^|[\s;&|(])(\.{1,2}/[\w./\-]+\.sh)\b'),
          re.compile(r'(?:^|&&|\|\||[;|(])\s*([\w./\-]+\.sh)\b'))


def is_config_file(path):
    name = os.path.basename(path)
    return name in CONFIG_NAMES or name.startswith(('jest.config.', 'vitest.config.')) or name.endswith('.sh')


def package_scripts(text):
    try:
        scripts = json.loads(text).get('scripts')
    except (ValueError, AttributeError):
        return {}
    return scripts if isinstance(scripts, dict) else {}


INSTALL_HOOKS = ['preinstall', 'install', 'postinstall', 'prepare', 'preprepare', 'postprepare']
NPM_INSTALL = {'ci', 'clean-install', 'ic', 'install-clean', 'isntall-clean', 'install', 'i', 'in', 'ins', 'inst', 'insta', 'instal', 'isnt',
               'isnta', 'isntal', 'isntall', 'add', 'rebuild', 'rb'}
NPM_INSTALL_TEST = {'install-test', 'it', 'install-ci-test', 'cit', 'clean-install-test', 'sit'}
PNPM_INSTALL = {'install', 'i', 'add', 'rebuild', 'rb'}
WRAPPERS = {'npx', 'cross-env', 'env', 'exec', 'time', 'nice', 'nohup', 'command', 'sudo'}
SHELLS = {'bash', 'sh', 'zsh', 'dash'}
ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')


def skip_prefix(tokens):
    """The command's tokens without leading NAME=value words and wrapper commands (npx, cross-env, env, exec, time, nice, nohup, command, sudo -E) with their options."""
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if ASSIGN.match(t):
            i += 1
        elif os.path.basename(t) in WRAPPERS:
            i += 1
            while i < len(tokens) and tokens[i].startswith('-'):
                i += 2 if tokens[i] == '-n' else 1
        else:
            break
    return tokens[i:]


def script_names(tokens):
    """The package scripts a command runs (install commands run their lifecycle hooks), or [] when it is not one of the recognised forms."""
    tokens = skip_prefix(tokens)
    if not tokens:
        return []
    tool = tokens[0]
    if tool == 'yarn' and all(t.startswith('-') for t in tokens[1:]):
        return list(INSTALL_HOOKS)
    if len(tokens) < 2:
        return []
    a1 = tokens[1]
    if tool == 'npm':
        if a1 in ('test', 't'):
            return ['test']
        if a1 in ('run', 'run-script') and len(tokens) > 2:
            return [tokens[2]]
        if a1 in NPM_INSTALL:
            return list(INSTALL_HOOKS)
        if a1 in NPM_INSTALL_TEST:
            return INSTALL_HOOKS + ['test']
    elif tool in ('pnpm', 'yarn'):
        if a1 == 'run':
            return [tokens[2]] if len(tokens) > 2 else []
        if tool == 'pnpm' and a1 in PNPM_INSTALL or tool == 'yarn' and a1 in ('install', 'add'):
            return list(INSTALL_HOOKS)
        if not a1.startswith('-'):
            return [a1]
    return []


def segments(text):
    """The simple commands of a command line as token lists (split at && || ; | & outside quotes), or None when it cannot be tokenised."""
    lex = shlex.shlex(text, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    out, cur = [], []
    try:
        for t in lex:
            if t and all(c in '();&|<>' for c in t):
                if any(c in ';&|' for c in t) and cur:
                    out.append(cur)
                    cur = []
            else:
                cur.append(t)
    except ValueError:
        return None
    if cur:
        out.append(cur)
    return out


def seg_files(seg, depth=0):
    """The .sh file one simple command runs (directly, or as the script of bash/sh/zsh/dash, also inside -c '...'), as (files, ok)."""
    toks = skip_prefix(seg)
    if not toks:
        return [], True
    if os.path.basename(toks[0]) not in SHELLS:
        return ([toks[0]] if toks[0].endswith('.sh') else []), True
    files, ok, j = [], True, 1
    while j < len(toks):
        t = toks[j]
        if t == '--':
            j += 1
            break
        if t in ('-o', '-O', '+o', '+O', '--rcfile', '--init-file'):
            j += 2
        elif re.match(r'^-[A-Za-z]+$', t) and 'c' in t:   # -c, -lc, -ec: the next word is a script line
            if j + 1 < len(toks) and depth < 3:
                files, ok = sh_files(toks[j + 1], depth + 1)
            return files, ok
        elif t.startswith(('-', '+')):
            j += 1
        else:
            break
    return [t for t in toks[j:] if t.endswith('.sh')][:1], True


def sh_files(text, depth=0):
    """The .sh files a command line or script text runs, by tokens (the SH_REF patterns find others): (files, ok); ok False when the text cannot be tokenised."""
    segs = segments(text)
    if segs is None:
        return [], False
    files, ok = [], True
    for seg in segs:
        f, o = seg_files(seg, depth)
        files += f
        ok = ok and o
    return files, ok


def reached_scripts(start, scripts):
    seen = []
    level = [start]
    for _ in range(6):
        nxt = []
        for name in level:
            if name in seen:
                continue
            seen.append(name)
            text = scripts.get(name)
            if not isinstance(text, str):
                continue
            nxt += [m.group(1) for m in SCRIPT_REF.finditer(text)]
            if NPM_TEST_REF.search(text):
                nxt.append('test')
        level = nxt
    return seen


def runner_findings(wt, base, cmds, changed):
    """Cheats in the files the acceptance commands run: package scripts (with their pre/post hooks and the .sh files they run) and bash scripts.
    changed: path -> status of the paths whose content changed."""
    findings = []
    now = {}
    old = {}
    pkg = os.path.join(wt, 'package.json')
    if os.path.isfile(pkg):
        with open(pkg, errors='replace') as fh:
            now = package_scripts(fh.read())
    shown = git(wt, 'show', '%s:package.json' % base)
    if shown.returncode == 0:
        old = package_scripts(shown.stdout)

    def file_changed(path):
        path = os.path.normpath(path)
        if path in changed and not any(f.get('file') == path for f in findings):
            findings.append(dict(kind='runner_file_changed', file=path))

    def any_sh_changed():
        for path in sorted(changed):
            if path.endswith('.sh'):
                file_changed(path)

    reported = []
    for cmd in cmds:
        segs = segments(cmd)
        if segs is None:   # cannot be read by tokens: every changed .sh counts
            any_sh_changed()
            parts = []
            for part in split_and(cmd):
                try:
                    parts.append(shlex.split(part))
                except ValueError:
                    continue
        else:
            parts = segs
        for tokens in parts:
            for start in script_names(tokens):
                names = reached_scripts(start, now) + [n for n in reached_scripts(start, old)]
                names = [n for i, n in enumerate(names) if n not in names[:i]]
                texts = []
                for name in names:
                    for hook in (name, 'pre' + name, 'post' + name):
                        if now.get(hook) != old.get(hook) and hook not in reported:
                            reported.append(hook)
                            findings.append(dict(kind='runner_script_changed', script=hook))
                        texts += [t for t in (now.get(hook), old.get(hook)) if isinstance(t, str)]
                for text in texts:
                    for rx in SH_REF:
                        for m in rx.finditer(text):
                            file_changed(m.group(1))
                    fs, ok = sh_files(text)
                    for f in fs:
                        file_changed(f)
                    if not ok:
                        any_sh_changed()
        if segs is not None:
            for seg in segs:
                fs, ok = seg_files(seg)
                for f in fs:
                    file_changed(f)
                if not ok:
                    any_sh_changed()
    return findings


HIDDEN_NAMES = {'conftest.py', 'pytest.ini', 'setup.cfg', 'tox.ini', 'sitecustomize.py', 'usercustomize.py'}


def hidden_candidate(path):
    name = os.path.basename(path)
    return name in HIDDEN_NAMES or name.endswith('.pth') or name.startswith(('jest.config.', 'vitest.config.'))


def global_excludes(wt):
    r = git(wt, 'config', 'core.excludesFile').stdout.strip()
    if not r:
        r = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'git', 'ignore')
    return os.path.realpath(os.path.expanduser(r))


SITE_PACKAGES = re.compile(r'^(?:lib|lib64)/(?:python|pypy)[0-9.]+/site-packages/|^Lib/site-packages/')


def hidden_test_config(wt, base, env):
    """Ignored files that configure the test runner, hidden by a rule the worker may have added.
    A rule from .git/info/exclude, the global excludes file or a .gitignore that is new or changed since base is flagged; an unchanged .gitignore
    (node_modules/, dist/, .venv/ that were there before) is not. A real venv is exempt: the folder with the .gitignore holds pyvenv.cfg, has no
    tracked file at base or in the worktree, and the candidate lies under lib/pythonX.Y/site-packages/ (or Lib/site-packages/) in it.
    env: the environment of the temporary index (what the worktree holds, ignored files left out)."""
    listed = git_bytes(wt, 'ls-files', '-o', '-i', '--exclude-standard', '-z', text=False).stdout.decode('utf-8', 'replace').split('\0')
    cands = [p for p in listed if p and hidden_candidate(p)]
    if not cands:
        return []
    r = git_bytes(wt, 'check-ignore', '-v', '--no-index', '-z', '--stdin', text=False, input=('\0'.join(cands) + '\0').encode('utf-8', 'surrogateescape'))
    out = r.stdout.decode('utf-8', 'replace').split('\0')
    info_ex = os.path.realpath(os.path.join(wt, git(wt, 'rev-parse', '--git-path', 'info/exclude').stdout.strip() or '.git/info/exclude'))
    glob_ex = global_excludes(wt)
    changed_cache = {}
    venv_cache = {}

    def real_venv_dir(d):
        """d (relative, '.' for the root) holds pyvenv.cfg and nothing tracked at base or in the worktree."""
        if d not in venv_cache:
            ok = d != '.' and os.path.isfile(os.path.join(wt, d, 'pyvenv.cfg'))
            if ok:
                ok = (not git(wt, 'ls-tree', '-r', '--name-only', base, '--', d).stdout.strip()
                      and not git_env(wt, env, 'ls-files', '--', d).stdout.strip())
            venv_cache[d] = ok
        return venv_cache[d]

    def gitignore_changed(src):
        if src not in changed_cache:
            if git(wt, 'cat-file', '-e', '%s:%s' % (base, src)).returncode != 0:
                changed_cache[src] = True
            else:
                old = git_bytes(wt, 'show', '%s:%s' % (base, src), text=False).stdout
                try:
                    with open(os.path.join(wt, src), 'rb') as fh:
                        changed_cache[src] = fh.read() != old
                except OSError:
                    changed_cache[src] = True
        return changed_cache[src]
    findings = []
    for k in range(0, len(out) - 3, 4):   # source NUL line NUL pattern NUL path NUL
        src, path = out[k], out[k + 3]
        real = os.path.realpath(os.path.join(wt, src))
        if real == info_ex or real == glob_ex:
            findings.append(dict(kind='hidden_test_config', file=path, source=src))
        elif os.path.basename(src) == '.gitignore':
            nsrc = os.path.normpath(src)
            d = os.path.dirname(nsrc) or '.'
            rel = os.path.normpath(os.path.relpath(path, d)).replace(os.sep, '/')
            if real_venv_dir(d) and SITE_PACKAGES.match(rel):
                continue
            if gitignore_changed(nsrc):
                findings.append(dict(kind='hidden_test_config', file=path, source=src))
    return findings


def integrity(wt, base, cmds=None):
    """Compares the whole worktree (commits, uncommitted and untracked files, not ignored) with the base, through a temporary index."""
    if not base:
        return dict(checked=False, reason='no base ref', cheat=False, findings=[])
    if git(wt, 'rev-parse', '--verify', '-q', base + '^{commit}').returncode != 0:
        return dict(checked=False, reason='base not found: %s' % base, cheat=False, findings=[])
    d = tempfile.mkdtemp(prefix='orca-oracle-idx-')
    try:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(d, 'index'))
        if git_env(wt, env, 'read-tree', 'HEAD').returncode != 0 or git_env(wt, env, 'add', '-A').returncode != 0:
            return dict(checked=False, reason='temporary index failed', cheat=False, findings=[])
        return integrity_diff(wt, base, cmds, env)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def integrity_diff(wt, base, cmds, env):
    ns = git_env(wt, env, 'diff', '--cached', '--name-status', '-z', '--no-renames', base)  # base -> worktree
    findings = []
    deleted = []
    modified = []
    all_deleted = []
    changed = {}
    raw = git_env(wt, env, 'diff', '--cached', '--raw', '-z', '--no-abbrev', '--no-renames', base).stdout.split('\0')
    for k in range(0, len(raw) - 1, 2):   # ":<mode> <mode> <sha> <sha> <status>" NUL path NUL
        fields = raw[k].lstrip(':').split(' ')
        path = raw[k + 1]
        st = fields[4][0]
        if st in 'MARCT' and (st == 'A' or fields[2] != fields[3]):
            changed[path] = st
        if TEST_PATH.search(path) and (st == 'T' or (st == 'A' and fields[1] == '120000')):
            findings.append(dict(kind='test_symlinked', file=path))
    nsf = ns.stdout.split('\0')
    for k in range(0, len(nsf) - 1, 2):   # status NUL path NUL
        st, path = nsf[k][0], nsf[k + 1]
        if st == 'D':
            all_deleted.append(path)
        if not TEST_PATH.search(path):
            continue
        if st == 'D':
            deleted.append(path)
        elif st in 'MR':
            modified.append(path)
    for p in deleted:
        if not subject_also_deleted(all_deleted, p):
            findings.append(dict(kind='test_deleted_without_subject', file=p))
    added_skip = 0
    removed = 0
    added = 0
    for p in modified:
        d = git_env(wt, env, 'diff', '--cached', '-U0', base, '--', p).stdout
        for l in d.splitlines():
            if l.startswith('+') and not l.startswith('+++'):
                added += 1
                if SKIP.search(l):
                    added_skip += 1
                    findings.append(dict(kind='skip_or_xfail_added', file=p))
            elif l.startswith('-') and not l.startswith('---'):
                removed += 1
    if removed > 20 and removed > 2 * max(added, 1):
        findings.append(dict(kind='tests_weakened', detail='%d test lines removed against %d added' % (removed, added)))
    runner = runner_findings(wt, base, cmds, changed) if cmds else []
    findings += runner
    findings += hidden_test_config(wt, base, env)
    reported_files = {f['file'] for f in runner if f['kind'] == 'runner_file_changed'}
    script_hit = any(f['kind'] == 'runner_script_changed' for f in runner)
    config = sorted(p for p, st in changed.items()
                    if is_config_file(p) and p not in reported_files and not (script_hit and p == 'package.json'))[:20]
    return dict(checked=True, base=base[:10], tests_deleted=len(deleted),
                tests_deleted_with_subject=sum(1 for p in deleted if subject_also_deleted(all_deleted, p)),
                tests_modified=len(modified), lines_added=added, lines_removed=removed,
                skips_added=added_skip, runner_config_changed=config, cheat=bool(findings), findings=findings[:10])


def wait_for_load(max_wait, max_load_ratio):
    """Waits (capped) until load1 < ratio x cores. Returns (seconds waited, load1 when it stopped waiting, target reached)."""
    ncpu = os.cpu_count() or 1
    t0 = time.time()
    load = os.getloadavg()[0]
    while load >= max_load_ratio * ncpu and time.time() - t0 < max_wait:
        time.sleep(min(10, max(1, max_wait - (time.time() - t0))))
        load = os.getloadavg()[0]
    return round(time.time() - t0, 1), round(load, 1), load < max_load_ratio * ncpu


def acceptance_commands(spec):
    rx = FIELDS['Observable acceptance']
    for name, body in sections(spec):
        if re.search(r'\b(?:%s)\b' % rx, name):
            return command_lines(body)
    return None


ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
FAILFILE = re.compile(r'(?:FAIL|FAILED|❯)\s+([\w./\-]+\.(?:test|spec)\.[jt]sx?|[\w./\-]+\.py)')


def failing_files(text):
    seen = []
    for m in FAILFILE.finditer(ANSI.sub('', text)):
        f = m.group(1)
        if f not in seen and not f.startswith('node_modules'):
            seen.append(f)
    return seen[:20]


def isolate_cmd(part, files):
    """Reruns only the failed files with the same runner (npm/pnpm/yarn test -- f..., pytest f...). None if unknown."""
    if not files:
        return None
    if re.match(r'^(?:npm|pnpm|yarn)(?: run)? test(?!:)\b', part):
        return shlex.split(part) + ['--'] + files
    if re.search(r'\bpytest\b', part):
        return shlex.split(part) + files
    if re.match(r'^(?:npx )?(?:vitest|jest)\b', part):
        base = shlex.split(part)
        return base + (['run'] if 'vitest' in part and 'run' not in base else []) + files
    return None


def run_cmd(wt, cmd, timeout, retries=1):
    """Runs each && segment; a failure is retried `retries` times. exit 0 after more than one attempt = flaky."""
    t0 = time.time()
    out = []
    code = None
    attempts = []
    isolated = 0
    env = {k: v for k, v in os.environ.items() if not re.search(r'KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL', k, re.I)}
    for extra in (os.path.join(wt, 'node_modules', '.bin'), os.path.join(wt, '.venv', 'bin')):
        if os.path.isdir(extra):
            env['PATH'] = extra + os.pathsep + env.get('PATH', '')
    for part in split_and(cmd):
        full = ''
        tail = ''
        for _ in range(1 + retries):
            t1 = time.time()
            try:
                r = subprocess.run(shlex.split(part), cwd=wt, capture_output=True, text=True, timeout=timeout, env=env)
                code = r.returncode
                full = r.stdout + r.stderr
                tail = full[-1500:]
            except subprocess.TimeoutExpired:
                code = 124
                full = ''
                tail = 'TIMEOUT %ss' % timeout
            except OSError as e:  # binary not found or not executable
                code = 127
                full = ''
                tail = str(e)
            attempts.append(dict(part=part.split()[0:3], exit=code, seconds=round(time.time() - t1, 1)))
            if code in (0, 127):
                break
        if code not in (0, 124, 127):  # persistent red: do the failed files pass on their own?
            files = failing_files(full)
            iso = isolate_cmd(part, files)
            if iso:
                t1 = time.time()
                try:
                    r = subprocess.run(iso, cwd=wt, capture_output=True, text=True, timeout=timeout, env=env)
                    attempts.append(dict(part=['isolated', '%d files' % len(files)], exit=r.returncode, seconds=round(time.time() - t1, 1)))
                    if r.returncode == 0:
                        code = 0
                        isolated = len(files)
                        tail = '(the %d failed file(s) pass on their own)' % len(files)
                except (subprocess.TimeoutExpired, OSError):
                    pass
        out.append(tail)
        if code != 0:
            break
    flaky = code == 0 and any(a['exit'] != 0 for a in attempts)
    return dict(cmd=cmd, exit=code, seconds=round(time.time() - t0, 1), attempts=len(attempts), flaky=flaky,
                flaky_isolated_files=isolated, tail=SECRET.sub('[REDACTED]', '\n'.join(out))[-600:])


def main(argv):
    ap = argparse.ArgumentParser(prog='verify_task.py')
    ap.add_argument('--worktree', default='.')
    ap.add_argument('--spec-file')
    ap.add_argument('--task')
    ap.add_argument('--run')
    ap.add_argument('--base')
    ap.add_argument('--timeout', type=int, default=600)
    ap.add_argument('--retries', type=int, default=1)
    ap.add_argument('--max-load', type=float, default=0.8)
    ap.add_argument('--wait-max', type=int, default=300)
    ap.add_argument('--no-wait', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--agent')
    ap.add_argument('--model')
    ap.add_argument('--config-sha')
    a = ap.parse_args(argv)
    if a.task is not None and re.sub(r'[^A-Za-z0-9_.-]', '_', a.task).strip('.') == '':
        print('verify_task.py: invalid task id: %s' % a.task, file=sys.stderr)
        return 2
    wt = os.path.abspath(a.worktree)
    if a.spec_file:
        with open(a.spec_file) as fh:
            spec = fh.read()
    elif a.task:
        spec = load_task_spec(a.task, a.run)
    else:
        sys.exit('verify_task.py: --spec-file or --task is required')
    task = a.task or os.path.basename(a.spec_file)
    cmds = acceptance_commands(spec)
    res = dict(task=task, worktree=os.path.basename(wt), pass_=False, cheat=False, status=None, commands=[], integrity=None)
    load_before = round(os.getloadavg()[0], 1)
    waited, load_start, reached = (0.0, load_before, True)
    if not a.no_wait and not a.dry_run:
        waited, load_start, reached = wait_for_load(a.wait_max, a.max_load)
    t0 = time.time()
    if not cmds:
        res['status'] = 'no_acceptance_command'
    else:
        checks = [(c, check_command(c)) for c in cmds]
        allowed = [c for c, (ok, _) in checks if ok]
        res['rejected'] = [dict(cmd=c[:120], reason=r) for c, (ok, r) in checks if not ok]
        if not allowed:
            res['status'] = 'command_not_allowed'
        elif a.dry_run:
            res['status'] = 'dry_run'
            res['commands'] = [dict(cmd=c) for c in allowed]
        else:
            res['commands'] = [run_cmd(wt, c, a.timeout, a.retries) for c in allowed]
            res['pass_'] = all(c['exit'] == 0 for c in res['commands'])
            res['flaky'] = any(c['flaky'] for c in res['commands'])
            if res['pass_']:
                res['status'] = 'pass_flaky' if res['flaky'] else 'pass'
            else:
                res['status'] = 'env_not_runnable' if any(c['exit'] == 127 for c in res['commands']) else 'fail'
            res['flaky_isolated'] = sum(c['flaky_isolated_files'] for c in res['commands'])
    res['integrity'] = integrity(wt, pick_base(wt, a.base), cmds)
    res['cheat'] = bool(res['integrity'].get('cheat'))
    ncpu = os.cpu_count() or 1
    load = os.getloadavg()[0]
    res.update(waited_for_load_s=waited, load_before_wait=load_before, load_at_start=load_start, load_target_reached=reached,
               load1=round(load, 1), ncpu=ncpu, high_load=load > ncpu, duration_s=round(time.time() - t0, 1),
               agent=a.agent, model=a.model, config_sha=a.config_sha, verified_at=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    res['pass'] = res.pop('pass_') and not res['cheat']
    if not a.dry_run:
        root = os.environ.get('ORCA_ROLES_ORACLE_OUT') or os.path.join(
            os.environ.get('XDG_CACHE_HOME') or os.path.join(os.path.expanduser('~'), '.cache'), 'orca-roles', 'oracle')
        d = os.path.join(root, re.sub(r'[^A-Za-z0-9_.-]', '_', task))
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'verify.json'), 'w') as fh:
            json.dump(res, fh, indent=1, ensure_ascii=False)
    print(json.dumps(res, ensure_ascii=False, indent=1))
    return 0 if res['pass'] else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
