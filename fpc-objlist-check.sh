#!/bin/sh
#
# fpc-objlist-check.sh <link.res> <objdir>
#
# Refuse an application blob that would be assembled from a stale object.
#
# The compiler writes the list of objects to link into link*.res. It names an
# object it built during this compile by bare filename, and an object it took
# from a unit search path by full path. fpc-app.mk builds the blob from exactly
# that list: bare names get the output directory, anything carrying a path is
# used as written.
#
# THE CASE THIS CATCHES. Give the compiler a replacement source for a unit that
# a search path already ships built — a `sysutils.pp` of your own, found before
# the runtime's — and it compiles yours, recompiles every unit that depends on
# it, and writes a fresh object for each into the output directory. It does not
# revise what it records as those units' object paths, so the list still names
# the built copies on the search path. The blob is then assembled from the very
# objects the recompile was meant to replace. Nothing else reports this: the
# compile is clean, the link is clean, and the blob's undefined symbols are the
# usual two, because the stock objects are internally consistent.
#
# The tell is the disagreement itself — the list names an object of some name
# from elsewhere while the output directory holds one of that name that this
# compile just wrote. The output directory is emptied before the compile, so
# every object in it is this compile's work and no timestamps are involved.
#
# WHAT IT DOES NOT CATCH, because there is nothing to catch. A unit no search
# path ships — this library's own `circlefpc`, or `dynlibs`, which the
# aarch64-embedded runtime does not carry — has no second object of its name.
# The compiler names it bare, it resolves to the output directory, and the only
# object of that name is the fresh one. Adding units to a project is safe;
# replacing units that already exist elsewhere is what this is about.
#
# Exit 0 when the list is consistent, 1 when it is not, 2 on a usage error.

set -u

res=${1:?usage: fpc-objlist-check.sh <link.res> <objdir>}
objdir=${2:?usage: fpc-objlist-check.sh <link.res> <objdir>}

[ -f "$res" ]    || { echo "fpc-objlist-check: no link response file at $res" >&2; exit 2; }
[ -d "$objdir" ] || { echo "fpc-objlist-check: no output directory at $objdir" >&2; exit 2; }

# The output directory named as the filesystem sees it, so that an entry
# pointing into it by full path is recognised as already correct rather than
# reported as a conflict with itself.
outdir=$(cd "$objdir" && pwd) || exit 2

objs=$(sed -n '/^INPUT (/,/^)/p' "$res" | grep -v '^INPUT (' | grep -v '^)')

stale=
for o in $objs; do
	# A bare name is the output directory's own object by definition.
	case $o in */*) ;; *) continue ;; esac

	d=$(cd "$(dirname "$o")" 2>/dev/null && pwd) || d=
	[ "$d" = "$outdir" ] && continue

	b=$(basename "$o")
	if [ -f "$objdir/$b" ]; then
		stale="$stale$o
"
	fi
done

[ -n "$stale" ] || exit 0

echo "$(basename "$res"): the object list names units this compile rebuilt." >&2
echo >&2
printf '%s' "$stale" | while read -r o; do
	echo "  the list says   $o" >&2
	echo "  this build wrote $objdir/$(basename "$o")" >&2
	echo >&2
done
cat >&2 <<EOF
Each of those units was compiled from a source found ahead of the built copy
the list points at, so the blob would be built from the copy the recompile was
meant to replace, and every other check would call the result correct.

A unit of a name that a search path already ships is a replacement, and this
build cannot carry one. Give it a name nothing else uses, or take the
replacement off the unit search path.
EOF
exit 1
