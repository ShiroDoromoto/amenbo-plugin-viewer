#!/usr/bin/env bash
# check-program-name-casing.sh — keep the product name lowercase where a machine resolves it.
#
# The product is written two ways on purpose: `Amenbo` when a sentence names it, `amenbo` when
# something resolves that spelling byte for byte — the command, the PATH entry, the repository
# slug. Prose is the common case and is left alone here; what this guard watches is the other
# side, because only that side breaks, and it breaks unevenly.
#
# PATH lookup is case-sensitive on Linux and case-folding on macOS and Windows. So `exec.Command
# ("Amenbo", …)` runs everywhere the author is likely to try it and resolves nowhere on the one
# platform they are least likely to have. Nothing fails at build time, no test notices — the
# plugin simply cannot reach the CLI once it is installed on Linux. That is the failure a red
# build cannot report, which is why it is asked here instead.
#
# Two positions are read, and only these two — the ones where the string IS the lookup:
#   - the program handed to Go's exec.Command / exec.LookPath, whether written there as a literal
#     or reached through a constant declared in the same tree
#   - the word tested by `command -v` / `which` / `type` in shell and make
#
# Usage: guards/check-program-name-casing.sh    (no args; reads the tracked tree)
# Exit codes: 0 = every resolved spelling is lowercase, 1 = one of them is not.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

python3 - <<'PY'
import re, subprocess, sys

# The name as a machine must see it. Anything differing from this only by case is the mistake
# being looked for — a different name altogether is somebody else's program and not ours to judge.
PROGRAM = "amenbo"

tracked = subprocess.run(
    ["git", "ls-files"], capture_output=True, text=True, check=True
).stdout.split()

# A constant's literal, so `exec.Command(amenboProgram, …)` is read as the name it stands for
# rather than skipped as an identifier this guard cannot see through.
CONST = re.compile(r'^\s*(?:const|var)\s+(\w+)\s*(?:=|\bstring\s*=)\s*"([^"]*)"', re.M)
# The first argument of the two calls that resolve a program on PATH.
EXEC = re.compile(r'exec\.(?:Command|LookPath)\(\s*(?:"([^"]*)"|(\w+))')
# The shell and make form. `type` is matched with a following word only, so a bare `type` in prose
# inside a recipe comment is not read as a lookup.
SHELL = re.compile(r'\b(?:command\s+-v|which|type)\s+"?([A-Za-z][\w.-]*)"?')

names = {}
for path in tracked:
    if path.endswith(".go"):
        try:
            body = open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        for name, value in CONST.findall(body):
            names[name] = value

wrong = []


def judge(path, line_number, spelling, position):
    if spelling != PROGRAM and spelling.lower() == PROGRAM:
        wrong.append((path, line_number, spelling, position))


for path in tracked:
    is_go = path.endswith(".go")
    is_shell = path.endswith((".sh", ".bash")) or path == "Makefile" or path.endswith("/Makefile")
    if not (is_go or is_shell):
        continue
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeDecodeError):
        continue
    for number, line in enumerate(lines, 1):
        if is_go:
            for literal, identifier in EXEC.findall(line):
                if literal:
                    judge(path, number, literal, "exec")
                elif identifier in names:
                    judge(path, number, names[identifier], f"exec, through {identifier}")
        if is_shell:
            # A recipe's comment is prose like any other, and prose is not this guard's business.
            if line.lstrip().startswith("#"):
                continue
            for word in SHELL.findall(line):
                judge(path, number, word, "PATH lookup")

if wrong:
    print(f"✗ program name casing: a machine resolves this spelling, and {PROGRAM!r} is the one it finds", file=sys.stderr)
    for path, number, spelling, position in wrong:
        print(f"    {path}:{number}: {spelling!r} ({position})", file=sys.stderr)
    print("  Prose naming the product stays 'Amenbo' — only what is resolved is lowered.", file=sys.stderr)
    sys.exit(1)

print(f"✓ program name casing: every resolved spelling of {PROGRAM!r} is lowercase")
PY
