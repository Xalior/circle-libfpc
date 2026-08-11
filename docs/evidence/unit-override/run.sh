#!/bin/bash
#
# Reproduce the runtime-unit override trap described in docs/BUILDING.md.
#
# It overrides the runtime's own SysUtils with a copy whose file functions
# call external C symbols that nothing defines, builds the application blob
# twice, and reads the answer out of the two blobs' undefined symbols:
#
#   built the way fpc-app.mk's rule builds it   -> the probe symbols are ABSENT
#   built with the recompiled units redirected  -> the probe symbols are there
#
# The first blob is the trap. It compiles, it links, and `make fpc-contract`
# calls it correct, while the code that was overridden is not in it.
#
# It then runs fpc-objlist-check.sh — the guard fpc-app.mk uses, the file
# itself and not a copy of it — over the same object list, which must refuse
# it. That makes this script the guard's regression test as well as the
# compiler behaviour's.
#
# THIS SCRIPT NEVER WRITES INTO THE RUNTIME TREE. Every source it needs is
# copied into its own work directory first, and the patch is applied to the
# copy. The runtime is read from and nothing else.
#
set -u

here=$(cd "$(dirname "$0")" && pwd)

# Build spoil goes outside this repository, so a run leaves the working tree
# clean. Set WORK to put it somewhere else.
work=${WORK:-${TMPDIR:-/tmp}/clf-unit-override}

die () { echo "$*" >&2; exit 2; }

: "${FPC:?set FPC to the aarch64-embedded cross-compiler (ppcrossa64)}"
: "${FPCRTL:?set FPCRTL to the built runtime unit directory (holding system.ppu)}"
: "${FPCRTLSRC:?set FPCRTLSRC to the runtime SOURCE tree (the directory holding rtl/)}"
: "${FPCBINUTILS:?set FPCBINUTILS to the directory holding aarch64-elf-as and aarch64-elf-ld}"

[ -x "$FPC" ]                     || die "no cross-compiler at $FPC"
[ -f "$FPCRTL/system.ppu" ]       || die "no system.ppu under $FPCRTL"
[ -f "$FPCRTLSRC/rtl/embedded/sysutils.pp" ] || die "no rtl/embedded/sysutils.pp under $FPCRTLSRC"
[ -x "$FPCBINUTILS/aarch64-elf-ld" ] || die "no aarch64-elf-ld under $FPCBINUTILS"

rtl=$FPCRTLSRC/rtl
src=$work/src
out=$work/out
rm -rf "$work"; mkdir -p "$src" "$out"

# ---------------------------------------------------------------------------
# Stage the units the compiler must see as SOURCE.
#
# Overriding SysUtils changes its interface checksum, so every unit compiled
# against the shipped one is refused and has to be rebuilt from source too.
# These four are that closure; everything else stays precompiled.
# ---------------------------------------------------------------------------
cp "$rtl/embedded/sysutils.pp" "$src/"
cp "$rtl/embedded/classes.pp"  "$src/"
cp "$rtl/objpas/types.pp"      "$src/"
cp "$rtl/objpas/typinfo.pp"    "$src/"
cp "$rtl/objpas/math.pp"       "$src/"
chmod u+w "$src"/*.pp

patch -s -p1 -d "$src" < "$here/sysutils-probe.patch" || die "the patch did not apply"

cp "$here/probe.pas" "$src/"

# ---------------------------------------------------------------------------
# Compile. The staged sources come FIRST on the unit path, ahead of the built
# runtime, which is what makes this an override rather than an ordinary build.
# ---------------------------------------------------------------------------
echo "== compiling =="
cd "$src" || exit 2
"$FPC" -Tembedded -Paarch64 \
  -XPaarch64-elf- -FD"$FPCBINUTILS" \
  -Fu"$src" -Fu"$FPCRTL" \
  -Fi"$rtl/objpas/sysutils" -Fi"$rtl/objpas/classes" \
  -Fi"$rtl/inc" -Fi"$rtl/embedded" -Fi"$rtl/aarch64" \
  -MDelphi -Sh -FU"$out" -FE"$out" \
  -Ch4194304 -Cs2097152 -s \
  probe.pas > "$work/compile.log" 2>&1
rc=$?
# The compiler's own exit status decides. Do not grep for "Error": the runtime
# has a local variable of that name and its "assigned but never used" note
# then reads as a failed compile.
if [ $rc -ne 0 ]; then
  grep -aE '(Fatal|Error|Warning):' "$work/compile.log" | tail -20
  die "the compiler exited $rc; see $work/compile.log"
fi

echo "-- units the compiler reported recompiling --"
grep -a '^Compiling' "$work/compile.log" | sed 's|.*/||'

# ppas.sh holds paths relative to the directory the compiler ran in, so it has
# to be run from there and not from inside the output directory.
sh "$out/ppas.sh" > "$work/ppas.log" 2>&1

echo
echo "-- objects the compiler actually wrote --"
( cd "$out" && ls -1 *.o 2>/dev/null | grep -v '^blob' )

res=$(ls "$out"/link*.res)
echo
echo "-- what the link response file names for those same units --"
sed -n '/^INPUT (/,/^)/p' "$res" | grep -v '^INPUT (' | grep -v '^)' \
  | grep -E 'sysutils|classes|types|typinfo|math'

# ---------------------------------------------------------------------------
# Blob one: exactly the rule fpc-app.mk uses. Bare names get the output
# directory; anything already carrying a path is taken as written.
# ---------------------------------------------------------------------------
objs=$(sed -n '/^INPUT (/,/^)/p' "$res" | grep -v '^INPUT (' | grep -v '^)')
asrecipe=$(echo "$objs" | sed "s|^\([^/]*\)$|$out/\1|")
"$FPCBINUTILS/aarch64-elf-ld" -r -o "$out/blob-as-recipe.o" $asrecipe || die "blob one did not link"

# ---------------------------------------------------------------------------
# Blob two: the same list, except that any unit whose object the compiler
# freshly wrote is taken from the output directory instead.
# ---------------------------------------------------------------------------
corrected=$(echo "$objs" | while read -r o; do
  b=$(basename "$o")
  if [ -f "$out/$b" ]; then echo "$out/$b"; else echo "$o"; fi
done)
"$FPCBINUTILS/aarch64-elf-ld" -r -o "$out/blob-corrected.o" $corrected || die "blob two did not link"

echo
echo "== the answer =="
for b in blob-as-recipe blob-corrected; do
  echo "-- $b.o leaves undefined --"
  "$FPCBINUTILS/aarch64-elf-nm" -u "$out/$b.o" | sed 's/^/   /'
done

# ---------------------------------------------------------------------------
# The guard fpc-app.mk runs before it uses that list — the shipped file, not a
# copy of it — over the very list the first blob was built from. It has to
# refuse it.
# ---------------------------------------------------------------------------
echo
echo "== the guard, on the same list =="
if sh "$here/../../../fpc-objlist-check.sh" "$res" "$out"; then
  guard=accepted
else
  guard=refused
fi

echo
if "$FPCBINUTILS/aarch64-elf-nm" -u "$out/blob-as-recipe.o" | grep -q probe_; then
  echo "UNEXPECTED: the recipe blob carries the override. The trap did not reproduce."
  exit 1
fi
if ! "$FPCBINUTILS/aarch64-elf-nm" -u "$out/blob-corrected.o" | grep -q probe_; then
  echo "UNEXPECTED: the corrected blob does not carry the override either."
  exit 1
fi
if [ "$guard" != refused ]; then
  echo "UNEXPECTED: the guard accepted an object list that drops the override."
  exit 1
fi
echo "Reproduced: the recipe blob leaves only the host-kernel contract and has"
echo "dropped the override; the corrected blob keeps it; and the guard refuses"
echo "the list that produced the first."
