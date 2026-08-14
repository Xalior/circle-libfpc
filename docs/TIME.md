# Elapsed time

**Time splits in two here, and the two halves are answered in different
places.** Elapsed time - how long something took, and how long to wait - is
the Arm generic timer's free-running counter, read directly. On this build
that counter is a processor system register, one per core, so the application
core reads it with an instruction: no device, no lock, no other core, and
therefore nothing to cross. Calendar time is the other half, and it goes through
`circle-libsdl2`: `SysUtils`' `Now`, `Date`, `Time` and `GetLocalTime` read it
through one call in `src/clock.cpp`, which is that library's replacement for
the C library's `_gettimeofday` and nothing else.

The System unit carries four routines for the first half.

- `CircleCounterFrequency` - how many ticks the counter counts in a second, as
  the firmware recorded it at boot. It is also the resolution: one tick is one
  part in this many of a second. Zero is a real answer and means the firmware
  left the register unset.
- `CircleCounter` - the counter itself, in its own ticks. It starts at zero
  when the board comes up and only goes forwards, and there are at least 56
  bits behind it, which at this rate is decades from wrapping.
- `CircleElapsedMicroseconds` - the same thing in microseconds.
- `CircleWaitMicroseconds` - wait for a stated length of time. The deadline is
  worked out once in ticks and the counter is read until it arrives; ticks are
  rounded up, so the wait is never short.

The counter reads themselves are three instructions in `src/counter.cpp`, and
all the arithmetic is on the Pascal side. A read is bracketed by an
instruction barrier, without which a timestamp can be taken before the work it
is meant to bracket has finished - so a read costs more than an unsynchronised
one would, and that cost sits inside every interval measured with it.

**A wait gives the core away.** The waiting loop's one non-arithmetic
statement services SDL and then hands the core to another Pascal thread, and
falls back on the processor's yield hint only when there is no other thread to
hand it to. The deadline is worked out before the loop and the counter read is
unchanged, so a wait that yields is exactly as long as one that did not, and
is never short.

`examples/m3` is a Pascal program that measures all of this on the board and
reports its own verdict, tolerance by tolerance, on the console.
