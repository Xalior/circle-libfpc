#!/bin/bash
#
# build-packages.sh — build the Free Pascal packages an application needs on
# aarch64-embedded, from the Free Pascal source tree, without writing to it.
#
# Free Pascal ships these as source but does not build them for this target.
# The cross-compiler was installed with `make buildbase` / `make installbase`,
# which build the compiler and the RTL and never enter packages/, so a program
# that says `uses SyncObjs` is told the unit does not exist. Nothing about the
# packages themselves is target-specific: they are algorithm and container code
# over SysUtils and Classes, which the embedded RTL already has.
#
# The packages' own makefiles are not used. They build a package at a time into
# the source tree, and this build writes nothing into that tree; the compiler
# resolves dependencies on its own from the source paths below, so naming the
# units an application asks for by name is enough.
#
# Output: one flat unit directory, given to a consumer's build as -Fu. See
# docs/PACKAGES.md for what each package needs at run time.
#
#   ./build-packages.sh              build into the default location
#   FPCPKGOUT=<dir> ./build-packages.sh
#
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"

# The Free Pascal trees, searched the same way fpc-app.mk searches them.
for d in ${RAPI_FPC_DIR:-} "$HERE/toolchains" "$HERE/../toolchains" \
         "$HERE/../../toolchains"; do
    [ -d "${d:-}/fpc-trunk-threads/packages" ] || continue
    FPCDIR="$(cd "$d" && pwd)"
    break
done

if [ -z "${FPCDIR:-}" ]; then
    echo "no Free Pascal source tree with packages/ found. Set RAPI_FPC_DIR." >&2
    exit 1
fi

SRC="$FPCDIR/fpc-trunk-threads"
PPC="$(ls "$FPCDIR"/fpc-embedded/lib/fpc/*/ppcrossa64 2>/dev/null | head -1)"
RTL="$SRC/rtl/units/aarch64-embedded"
PKG="$SRC/packages"
OUT="${FPCPKGOUT:-$FPCDIR/fpc-packages-embedded/units/aarch64-embedded}"

# The assembler and linker Free Pascal drives for this target. Its tool prefix
# is aarch64-elf-, not the Arm GNU toolchain's aarch64-none-elf-.
for d in /opt/homebrew/opt/aarch64-elf-binutils/bin \
         /usr/local/opt/aarch64-elf-binutils/bin; do
    [ -d "$d" ] && { BINUTILS="$d"; break; }
done

[ -n "${PPC:-}" ]      || { echo "no ppcrossa64 in $FPCDIR/fpc-embedded" >&2; exit 1; }
[ -d "$RTL" ]          || { echo "no threading RTL at $RTL" >&2; exit 1; }
[ -n "${BINUTILS:-}" ] || { echo "no aarch64-elf-binutils found" >&2; exit 1; }

mkdir -p "$OUT"

# THE UNITS AN APPLICATION ASKS FOR BY NAME.
#
# Everything else in the output directory is a dependency the compiler reached
# on its own: DateUtils and system.timespan under SyncObjs; Rtti, Variants and
# VarUtils under Generics.Collections; paszlib under the PNG reader; pasjpeg
# under the JPEG reader.
UNITS="
$PKG/fcl-base/src/syncobjs.pp
$PKG/rtl-generics/src/generics.collections.pas
$PKG/rtl-objpas/src/inc/strutils.pp
$PKG/fcl-image/src/fpimage.pp
$PKG/fcl-image/src/fpreadbmp.pp
$PKG/fcl-image/src/fpwritebmp.pp
$PKG/fcl-image/src/fpreadpng.pp
$PKG/fcl-image/src/fpwritepng.pp
$PKG/fcl-image/src/fpreadgif.pas
$PKG/fcl-image/src/fpreadjpeg.pas
"

echo "compiler : $PPC"
echo "RTL      : $RTL"
echo "packages : $PKG"
echo "output   : $OUT"
echo

for u in $UNITS; do
    name="$(basename "$u")"
    printf '  %-28s ' "$name"
    if "$PPC" -Tembedded -Paarch64 -XPaarch64-elf- -FD"$BINUTILS" \
        -Fu"$RTL" -Fu"$OUT" \
        -Fu"$PKG/fcl-base/src"       -Fi"$PKG/fcl-base/src" \
        -Fu"$PKG/rtl-objpas/src/inc"  -Fi"$PKG/rtl-objpas/src/inc" \
        -Fu"$PKG/rtl-generics/src"    -Fi"$PKG/rtl-generics/src" \
                                      -Fi"$PKG/rtl-generics/src/inc" \
        -Fu"$PKG/fcl-image/src"       -Fi"$PKG/fcl-image/src" \
        -Fu"$PKG/paszlib/src"         -Fi"$PKG/paszlib/src" \
        -Fu"$PKG/hash/src"            -Fi"$PKG/hash/src" \
        -Fu"$PKG/pasjpeg/src"         -Fi"$PKG/pasjpeg/src" \
        -FU"$OUT" -FE"$OUT" -Sh \
        "$u" > "$OUT/$name.log" 2>&1
    then
        echo "ok"
    else
        echo "FAILED — see $OUT/$name.log"
        grep -E 'Fatal|Error' "$OUT/$name.log" | head -5 | sed 's/^/      /'
        exit 1
    fi
done

echo
echo "$(ls "$OUT"/*.ppu | wc -l | tr -d ' ') units in $OUT"
