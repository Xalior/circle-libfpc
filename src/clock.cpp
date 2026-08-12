//
// clock.cpp — calendar time, which is the half of time the application core
// does not answer for itself.
//
// WHAT CALENDAR TIME IS ON THIS BOARD, AND WHO ANSWERS IT. There is no
// battery-backed clock on a Raspberry Pi, so nothing on the board remembers
// the date across a power cycle. circle-libsdl2 answers the question anyway,
// and it does so by replacing the C library's own `_gettimeofday` from an
// object every consumer links. Read that override in circle-libsdl2 for what
// it decides; the short of it is that the kernel's timer object answers when
// it holds a plausible date, and otherwise the answer is circle-libsdl2's own
// build time plus however long the board has been up.
//
// So the date a Pascal program reads here is the date a C program on this
// board reads, to the microsecond, because it is the same function. It is
// well defined and it is not the real date. Nothing in this library corrects
// it, seeds it, or replaces it.
//
// WHY `_gettimeofday` AND NOT `gettimeofday`. The underscored name is the one
// circle-libsdl2 defines, so calling it reaches that library and nothing else.
// The C library's `gettimeofday` wrapper reaches the same function eventually,
// but it goes through newlib's reentrancy struct and writes `errno` on the way
// — and errno is one variable shared by every core here, which is exactly why
// circle-libsdl2's file service reports a negated error number instead of
// setting one. Writing it from the application core would put a value into
// storage the core that owns the devices is using.
//
// THE CROSSING IS INSIDE circle-libsdl2 AND NOT HERE. Where the answer comes
// from the kernel's timer object, that library reads it on core 0 through its
// own mailbox; where it comes from the free-running counter, that is a
// processor register any core may read. Neither path reaches a device from
// this core, and this file reaches nothing at all: it is one call and a pair
// of assignments.
//
#include "libfpc.h"

#include <sys/time.h>

// circle-libsdl2's replacement for the C library's clock, declared here
// rather than included: <sys/time.h> declares the wrapper, not this.
extern "C" int _gettimeofday(struct timeval *ptimeval, void *ptimezone);

// THE DATE AND TIME, as seconds since 1970-01-01 UTC and microseconds within
// the second.
//
// Zero on success and -1 when the clock refused to answer, in which case
// neither output is written. There is no time zone here and none is applied:
// the answer is UTC, and a board with no clock has nowhere to keep a zone
// setting either.
extern "C" int LibFPC_CalendarTime(s64 *pSeconds, u32 *pMicroSeconds)
{
    struct timeval tv;

    if (_gettimeofday(&tv, 0) != 0)
    {
        return -1;
    }

    if (pSeconds != 0)
    {
        *pSeconds = (s64) tv.tv_sec;
    }

    if (pMicroSeconds != 0)
    {
        *pMicroSeconds = (u32) tv.tv_usec;
    }

    return 0;
}
