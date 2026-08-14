//
// clock.cpp - calendar time, which is the half of time the application core
// does not answer for itself.
//
// Calendar time, answered by circle-libsdl2. There is no battery-backed
// clock on a Raspberry Pi, so nothing on the board remembers the date
// across a power cycle. circle-libsdl2 answers the question anyway, by
// replacing the C library's own `_gettimeofday` from an object every
// consumer links: the kernel's timer object answers when it holds a
// plausible date, and otherwise the answer is circle-libsdl2's own build
// time plus however long the board has been up.
//
// So the date a Pascal program reads here is the date a C program on this
// board reads, to the microsecond, because it is the same function. It is
// well defined and it is not the real date. Nothing in this library
// corrects it, seeds it, or replaces it.
//
// This calls `_gettimeofday` rather than `gettimeofday`: the underscored
// name is the one circle-libsdl2 defines, so calling it reaches that
// library and nothing else. The C library's `gettimeofday` wrapper reaches
// the same function eventually, but goes through newlib's reentrancy
// struct and writes `errno` on the way, and errno is one variable shared
// by every core here. Writing it from the application core would put a
// value into storage the core that owns the devices is using.
//
// The crossing is inside circle-libsdl2, not here. Where the answer comes
// from the kernel's timer object, that library reads it on core 0 through
// its own mailbox; where it comes from the free-running counter, that is a
// processor register any core may read. Neither path reaches a device from
// this core, and this file reaches nothing at all: it is one call and a
// pair of assignments.
//
#include "libfpc.h"

#include <sys/time.h>

// circle-libsdl2's replacement for the C library's clock, declared here
// rather than included: <sys/time.h> declares the wrapper, not this.
extern "C" int _gettimeofday(struct timeval *ptimeval, void *ptimezone);

// The date and time, as seconds since 1970-01-01 UTC and microseconds
// within the second.
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
