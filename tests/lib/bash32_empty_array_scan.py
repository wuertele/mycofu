#!/usr/bin/env python3
"""Scanner for the bash-3.2 + set -u + empty-array expansion hazard (#410).

On bash 3.2 (macOS operator workstation /bin/bash 3.2.57), expanding an
EMPTY array as "${ARR[@]}" / "${ARR[*]}" under `set -u` aborts the script
with "ARR[@]: unbound variable". bash >= 4.4 (the Linux cicd runner)
treats it as harmless, so the bug is invisible to CI and only fires on
the workstation.

This scanner emits every UNGUARDED bare "${ARR[@]}" / "${ARR[*]}"
expansion of an array that is initialized empty (`ARR=()`,
`local ARR=()`, `declare -a ARR=()`, ...) in a scanned .sh file that runs
under `set -u`. "Unguarded" means NOT the safe default-word idioms
`${ARR[@]+...}` / `"${ARR[@]:-}"` and NOT preceded within WINDOW lines by
a `${#ARR[@]}` count reference.

Output: one line per distinct expansion as a stable, line-number-free key

    <relpath>\t<ARRAY>\t<sym>

sorted and de-duplicated. `test_bash32_empty_array_ratchet.sh` diffs this
against tests/fixtures/bash32_empty_array_baseline.txt: any NET-NEW key is
a regression (a newly-introduced unguarded expansion, INCLUDING an
idiom->bare flip of a currently-safe array such as NIX_BUILD_FLAGS,
because that adds a key that was not present before).

Usage:  bash32_empty_array_scan.py <scripts_dir>
"""
import os
import re
import sys

WINDOW = 10

SET_U = re.compile(r'(^|\s|;)set\s+[-+][a-z]*u|set\s+-o\s+nounset')
# NAME=()  — anywhere on the line (handles `local NAME=()`, `declare -a
# NAME=()`, and multiple `local a=() b=()` on one line).
EMPTY_INIT = re.compile(r'(?:^|;|\s|\b)([A-Za-z_][A-Za-z0-9_]*)=\(\s*\)')
# bare "${NAME[@]}" / "${NAME[*]}" — NOT ${NAME[@]+...}, NOT "${NAME[@]:-}"
# (the ':-' form ends in ':-}' so it does not match), NOT ${#NAME[@]} (the
# leading '#' is excluded by the identifier class).
BARE = re.compile(r'"\$\{([A-Za-z_][A-Za-z0-9_]*)\[([@*])\]\}"')


def strip_comment(line):
    """Drop a trailing/whole-line bash comment, protecting ${#..} and $#."""
    out = []
    i, n = 0, len(line)
    quote = None
    while i < n:
        c = line[i]
        if quote:
            out.append(c)
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            out.append(c)
            i += 1
            continue
        if c == '#':
            prev = line[i - 1] if i > 0 else ''
            if (i == 0 or prev.isspace()) and prev not in ('$', '{'):
                break
        out.append(c)
        i += 1
    return ''.join(out)


def scan(scripts_dir):
    keys = set()
    for root, _dirs, files in os.walk(scripts_dir):
        for fn in sorted(files):
            if not fn.endswith('.sh'):
                continue
            path = os.path.join(root, fn)
            try:
                with open(path, encoding='utf-8', errors='replace') as fh:
                    raw = fh.read()
            except OSError:
                continue
            if not SET_U.search(raw):
                continue
            lines = [strip_comment(l) for l in raw.splitlines()]
            empty_arrays = set()
            for l in lines:
                for m in EMPTY_INIT.finditer(l):
                    empty_arrays.add(m.group(1))
            if not empty_arrays:
                continue
            rel = os.path.relpath(path, scripts_dir)
            for i, line in enumerate(lines):
                for m in BARE.finditer(line):
                    name, sym = m.group(1), m.group(2)
                    if name not in empty_arrays:
                        continue
                    if re.search(r'\$\{' + re.escape(name) + r'\[[@*]\]\+', line):
                        continue  # ${NAME[@]+...} safe idiom
                    cg = re.compile(r'\$\{#' + re.escape(name) + r'\[[@*]\]\}')
                    window = '\n'.join(lines[max(0, i - WINDOW): i + 1])
                    if cg.search(window):
                        continue  # count-guarded
                    keys.add((rel, name, sym))
    return keys


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: bash32_empty_array_scan.py <scripts_dir>\n")
        return 2
    for rel, name, sym in sorted(scan(sys.argv[1])):
        print(f"{rel}\t{name}\t{sym}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
