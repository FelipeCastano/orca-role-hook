"""Allowlist of acceptance commands. verify_task runs ONLY what passes check_command; anything else is reported as not allowed."""
import re
import shlex

RUNNERS = [  # regexes over the whole command (one "&&" segment at a time)
    r'(?:uv run )?(?:python3? -m )?pytest(?: [\w./:=\-\[\]"\']+)*',
    r'(?:uv run )?ruff (?:check|format --check)(?: [\w./\-]+)*',
    r'(?:uv run )?mypy(?: [\w./\-]+)*',
    r'(?:npm|pnpm|yarn)(?: run)? (?:test|lint|build|typecheck|check|ci|e2e|test:[\w:\-]+|lint:[\w:\-]+)(?: [\w./:=\-]+)*',
    r'(?:npm|pnpm|yarn) (?:ci|install --frozen-lockfile)',
    r'(?:npx )?(?:vitest|jest|tsc|eslint|playwright test)(?: [\w./:=\-]+)*',
    r'make [\w:\-]+(?: [\w:=.\-]+)*',
    r'go (?:test|vet|build)(?: [\w./:=\-]+)+',
    r'cargo (?:test|check|clippy|build)(?: [\w=.\-]+)*',
    r'bash [\w./\-]+\.sh(?: [\w./:=\-]+)*',
]
DENY_CHARS = re.compile(r'[|><`$]|\$\(|&(?!&)|\b(?:rm|sudo|curl|wget|ssh|scp|dd|mkfs|chmod|chown|kill|pkill|eval|git (?:push|reset|clean|checkout|rebase)|docker|kubectl)\b|\.\./|(?:^|\s)/(?!dev/null)')


def command_lines(section):
    """Candidate commands of a section, from the most explicit source present: lines of ``` blocks; else '$ cmd' lines; else inline `cmd` spans."""
    cands = []
    blocks = re.findall(r'```[^\n]*\n(.*?)```', section, re.S)
    dollars = [m.group(1).strip() for m in (re.match(r'^\s*\$\s+(.+)$', l) for l in section.splitlines()) if m]
    if blocks:
        for blk in blocks:
            cands += [l.strip().lstrip('$ ').strip() for l in blk.splitlines() if l.strip() and not l.strip().startswith('#')]
    elif dollars:
        cands = dollars
    else:
        for m in re.finditer(r'`([^`\n]{4,200})`', section):
            t = m.group(1).strip()
            if re.match(r'^(?:uv run |npx |python3? -m )?(?:pytest|ruff|mypy|npm|pnpm|yarn|vitest|jest|tsc|eslint|make|go|cargo|bash)\b', t):
                cands.append(t)
    seen = set()
    out = []
    for c in (strip_comment(x) for x in cands):
        if c and c not in seen:
            seen.add(c)
            out.append(c)
    return out


def strip_comment(c):
    return re.sub(r'\s+#.*$', '', c).strip()


def split_and(cmd):
    return [p.strip() for p in re.split(r'\s*&&\s*', cmd) if p.strip()]


def check_command(cmd):
    """(ok, reason). Chains of allowed commands joined with && are accepted; no pipes, redirections, substitutions or dangerous commands."""
    if DENY_CHARS.search(cmd.replace('&&', ' ')):
        return False, 'contains a pipe, redirection, substitution or a command outside the safe list'
    for part in split_and(cmd):
        try:
            shlex.split(part)
        except ValueError:
            return False, 'unclosed quote'
        if not any(re.fullmatch(rx, part) for rx in RUNNERS):
            return False, '"%s..." is not in the list of allowed runners' % part.split()[0]
    return True, 'ok'
