#!/bin/sh
#
# fpc-compile.sh — compile one Free Pascal program module into relocatable
# objects, and decide honestly whether that worked.
#
#   fpc-compile.sh <log> <nm> <object> <compiler> <compiler args...>
#
# WHY THIS IS NOT A PLAIN COMPILER CALL
#
# The circlesdl2 target produces no executable. Circle's build does the link
# (CLF-022), so the target registers a linker class with no ExeCmd and leaves
# MakeExecutable at the base class, which refuses:
#
#     Error: (9018) Creation of Executables not supported
#
# The compiler emits every object first and reaches that refusal afterwards,
# so the objects on disk are complete and correct — but the compiler has
# reported an error and exits non-zero. Free Pascal offers no way to ask for
# the objects alone: -Cn ("omit linking stage") is read only inside
# TExternalLinker's own script-driven paths, and the call in pmodules.pas is
# unconditional for a program module at compile level 1.
#
# So the exit code cannot be the test, and "ignore the exit code" cannot be
# the answer either — that would swallow every real compile error with it.
#
# WHAT IS TESTED INSTEAD
#
#   - The compiler reported AT MOST ONE error, and if it reported one it was
#     message 9018 and nothing else. Any other error, or a second one, fails
#     the build with the compiler's own output.
#   - The object asked for exists and defines PASCALMAIN, which is the entry
#     point a host kernel calls. An object without it is not a program module,
#     whatever the compiler said.
#
# -vq is what makes the first test possible: it puts Free Pascal's message
# numbers in the output, so the refusal is recognised by its number rather
# than by matching English text that a translation or a release could change.
#

set -eu

if [ $# -lt 4 ]; then
    echo "usage: $0 <log> <nm> <object> <compiler> [args...]" >&2
    exit 2
fi

LOG=$1
NM=$2
OBJECT=$3
COMPILER=$4
shift 4

rm -f "$OBJECT"

set +e
"$COMPILER" "$@" > "$LOG" 2>&1
set -e

# Free Pascal writes, with -vq:   file.pas(6) Error: (9018) some text
ERRORS=$(grep -c ' Error: (' "$LOG" || true)
REFUSALS=$(grep -c ' Error: (9018)' "$LOG" || true)

if [ "$ERRORS" -gt 1 ] || [ "$ERRORS" -ne "$REFUSALS" ]; then
    echo "fpc-compile: the compiler reported errors beyond its refusal to link." >&2
    cat "$LOG" >&2
    exit 1
fi

if [ ! -f "$OBJECT" ]; then
    echo "fpc-compile: no object at $OBJECT." >&2
    cat "$LOG" >&2
    exit 1
fi

if ! "$NM" -g --defined-only "$OBJECT" | grep -q ' PASCALMAIN$'; then
    echo "fpc-compile: $OBJECT defines no PASCALMAIN, so it is not a program module." >&2
    "$NM" -g --defined-only "$OBJECT" >&2
    exit 1
fi

exit 0
