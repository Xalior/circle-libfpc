#!/bin/bash
#
# make-fixed-rtl.sh — produce a runtime unit directory in which heapmgr's
# MinBlock is large enough for the free-list node it writes, so the same
# program can be booted with the defect and without it.
#
# IT DOES NOT MODIFY THE FREE PASCAL SOURCE TREE. That tree is upstream and is
# never edited. This script copies one file out of it, changes one constant in
# the copy, compiles that copy, and builds a unit directory made of symbolic
# links to every other unit of the real runtime plus the rebuilt heapmgr. The
# result is a proving artefact in the repository's scratch area, thrown away
# and remade at will, committed nowhere.
#
# The change, in full:
#
#     const MinBlock = 16;   ->   const MinBlock = 24;
#
# 24 is SizeOf(THeapBlock) on a 64-bit target: Size, Next and EndAddr at eight
# bytes each. It is already a multiple of the eight-byte alignment the
# allocator rounds to, so nothing else has to move.
#
# Usage:  ./make-fixed-rtl.sh
# Prints the unit directory to give the build as FPCRTL.
#
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"

for d in ${RAPI_FPC_DIR:-} "$HERE/../../toolchains" "$HERE/../../../toolchains" \
         "$HERE/../../../../toolchains"; do
    [ -d "${d:-}/fpc-trunk-threads/rtl/units/aarch64-embedded" ] || continue
    FPCDIR="$(cd "$d" && pwd)"
    break
done
[ -n "${FPCDIR:-}" ] || { echo "no Free Pascal tree found. Set RAPI_FPC_DIR." >&2; exit 1; }

SRC="$FPCDIR/fpc-trunk-threads"
RTL="$SRC/rtl/units/aarch64-embedded"
PPC="$(ls "$FPCDIR"/fpc-embedded/lib/fpc/*/ppcrossa64 2>/dev/null | head -1)"

for d in /opt/homebrew/opt/aarch64-elf-binutils/bin \
         /usr/local/opt/aarch64-elf-binutils/bin; do
    [ -d "$d" ] && { BINUTILS="$d"; break; }
done
[ -n "${PPC:-}" ]      || { echo "no ppcrossa64 found" >&2; exit 1; }
[ -n "${BINUTILS:-}" ] || { echo "no aarch64-elf-binutils found" >&2; exit 1; }

# The scratch area, which is gitignored and is where proving artefacts belong.
WORK="$HERE/../../../scratchpad/minblock-fixed-rtl"
OUT="$WORK/units"
rm -rf "$WORK"
mkdir -p "$WORK/src" "$OUT"

cp "$SRC/rtl/embedded/heapmgr.pp" "$WORK/src/heapmgr.pp"

# One constant, and only in our copy.
sed -i.orig 's/^\( *\)MinBlock = 16;/\1MinBlock = 24;/' "$WORK/src/heapmgr.pp"
if ! grep -q 'MinBlock = 24;' "$WORK/src/heapmgr.pp"; then
    echo "MinBlock = 16 was not found in heapmgr.pp; upstream has changed." >&2
    exit 1
fi
echo "changed in the copy only:"
diff "$WORK/src/heapmgr.pp.orig" "$WORK/src/heapmgr.pp" | sed 's/^/    /' || true

# Every other unit of the real runtime, by symbolic link, so nothing is
# duplicated and nothing can drift.
for f in "$RTL"/*.ppu "$RTL"/*.o; do
    b="$(basename "$f")"
    case "$b" in
        heapmgr.ppu|heapmgr.o) continue ;;
    esac
    ln -sf "$f" "$OUT/$b"
done

# heapmgr on its own, compiled the way the runtime compiles it: -Us marks it a
# system unit, which it is.
"$PPC" -Tembedded -Paarch64 -XPaarch64-elf- -FD"$BINUTILS" \
    -Fu"$OUT" -Fi"$SRC/rtl/embedded" -Fi"$SRC/rtl/inc" -Fi"$SRC/rtl/aarch64" \
    -FU"$OUT" -FE"$OUT" \
    "$WORK/src/heapmgr.pp" > "$WORK/heapmgr-build.log" 2>&1 || {
        echo "the corrected heapmgr would not compile; see $WORK/heapmgr-build.log" >&2
        tail -20 "$WORK/heapmgr-build.log" >&2
        exit 1
    }

echo
echo "corrected runtime units: $OUT"
