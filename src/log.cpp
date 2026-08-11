//
// log.cpp — everything the Pascal side prints, and where it is allowed to go.
//
// THIS LIBRARY OWNS NO HARDWARE. It supplies the Free Pascal runtime — the
// memory manager, the thread manager, start-up and halt — and nothing that
// touches the outside world. A Pascal program here is an application, not a
// kernel: it runs on a core the way a guest runs on a virtual machine, and a
// guest does not drive a UART.
//
// That is not tidiness. A console is a device, a device belongs to core 0, and
// a Pascal thread runs on a core that is not core 0. Writing a device from
// there is a cross-core hardware access with nothing serialising it against
// core 0 doing the same, and it is the reason this file exists rather than a
// pointer to a CDevice.
//
// WHERE TEXT GOES. Out through circle-libsdl2, which is the I/O surface a
// Pascal program on this platform has. Its SDL2Circle_LogBytes takes output in
// whatever pieces it was written in — an application's stdout, which is
// exactly what Pascal's Write produces — assembles it into lines, and carries
// each one from whatever core produced it to the core that owns the console.
// Nothing here formats a device, waits on one, or knows which one it is.
//
// WHEN circle-libsdl2 IS NOT IN THE IMAGE. The reference to it is weak, so an
// image that does not link it still links. There is then no I/O surface, and
// this file falls back to the one console every Circle kernel already owns:
// the host's own CLogger. It is the HOST's device, not this library's, and the
// rule that made the fallback necessary is still kept — core 0 writes through
// the logger, and any other core puts its line in a ring of its own for core 0
// to drain. The guest never reaches a device on either path.
//
//   A host kernel with no CLogger sees nothing. Circle's CLogger::Get makes a
//   logger with no target and a severity floor of LogPanic when a kernel has
//   not made one, so every line is silently dropped. That is a host kernel
//   bug, and it looks exactly like a Pascal program that never ran.
//
#include "sched.h"
#include <circle-libfpc/fpc.h>
#include <circle/logger.h>
#include <circle/macros.h>
#include <circle/timer.h>
#include <circle/sysconfig.h>

#ifdef ARM_ALLOW_MULTI_CORE
	#include <circle/multicore.h>
	#define CLF_LOG_CORES		CORES
#else
	#define CLF_LOG_CORES		1
#endif

// circle-libsdl2's byte-oriented log entry, when the image has one. Weak: the
// reference resolves to zero rather than failing the link when it does not.
extern "C" void SDL2Circle_LogBytes (const char *pFrom, const char *pBytes,
				     unsigned nLength) WEAK;

// The tag every line the Pascal program itself prints carries.
static const char FromPascal[] = "pascal";

// Circle's CLogger::WriteNoAlloc assembles source, ": ", the message and a
// newline into a buffer of 200 bytes and does not check. A line is kept short
// enough that the whole of that cannot overflow, whatever tag it carries.
#define CLF_LOG_LINE_MAX	160

// Per core, and sized for a start-up burst rather than a line or two: the
// lines that matter most are the ones a program produces while it is coming
// up, and those are the ones a small ring loses. MUST BE A POWER OF TWO — head
// and tail are free-running counters reduced modulo this, and a size that does
// not divide 2^32 would make them disagree the first time they wrap.
#define CLF_LOG_RING_BYTES	16384

// What one drain will print before returning. The console is far slower than
// any core, and a producer that never waits keeps a ring permanently
// non-empty: a drain whose only exit is an empty ring would never return at
// all, and core 0 would stop doing everything else it owns. A budget in TIME,
// because the cost of a line is the console's and not the line's.
#define CLF_LOG_DRAIN_MAX_US	2000
#define CLF_LOG_DRAIN_MAX_LINES	16

struct CLFLogRec
{
	const char	*pFrom;		// a literal, never a buffer: printed later
	unsigned	 nLength;
};

struct CLFLogRing
{
	volatile unsigned  nTail;			// the owning core writes
	volatile unsigned  nHead;			// core 0 reads
	volatile unsigned  nDropped;
	char		   Data[CLF_LOG_RING_BYTES];
} ALIGN (64);

static CLFLogRing s_Ring[CLF_LOG_CORES];

// Output arrives in whatever pieces it was written in, and a log carries
// lines. One line under assembly per core, touched only by that core.
struct CLFLineBuffer
{
	unsigned	 nLength;
	const char	*pFrom;
	char		 Text[CLF_LOG_LINE_MAX + 1];
};

static CLFLineBuffer s_Line[CLF_LOG_CORES];

static unsigned s_nDroppedTotal[CLF_LOG_CORES];
static boolean  s_bDropping[CLF_LOG_CORES];

static inline unsigned CLFLogThisCore (void)
{
#ifdef ARM_ALLOW_MULTI_CORE
	return CMultiCoreSupport::ThisCore () % CLF_LOG_CORES;
#else
	return 0;
#endif
}

// ---------------------------------------------------------------------------
// The fallback: a ring per core, drained by core 0 into the host's logger
// ---------------------------------------------------------------------------

static void CLFRingCopyIn (CLFLogRing *pRing, unsigned nAt, const void *pSrc,
			   unsigned nLength)
{
	const char *p = (const char *) pSrc;
	for (unsigned i = 0; i < nLength; i++)
	{
		pRing->Data[(nAt + i) % CLF_LOG_RING_BYTES] = p[i];
	}
}

static void CLFRingCopyOut (CLFLogRing *pRing, unsigned nAt, void *pDst,
			    unsigned nLength)
{
	char *p = (char *) pDst;
	for (unsigned i = 0; i < nLength; i++)
	{
		p[i] = pRing->Data[(nAt + i) % CLF_LOG_RING_BYTES];
	}
}

// A full ring DROPS the line and counts it. Losing a line is bad; stalling the
// core that produced it, or overwriting one already waiting, is worse.
static void CLFRingPush (const char *pFrom, const char *pText, unsigned nLength)
{
	CLFLogRing *pRing = &s_Ring[CLFLogThisCore ()];

	unsigned nTail = __atomic_load_n (&pRing->nTail, __ATOMIC_RELAXED);
	unsigned nHead = __atomic_load_n (&pRing->nHead, __ATOMIC_ACQUIRE);
	unsigned nNeed = sizeof (CLFLogRec) + nLength;

	if (CLF_LOG_RING_BYTES - (nTail - nHead) < nNeed)
	{
		__atomic_fetch_add (&pRing->nDropped, 1U, __ATOMIC_RELAXED);
		return;
	}

	CLFLogRec Rec;
	Rec.pFrom = pFrom;
	Rec.nLength = nLength;

	CLFRingCopyIn (pRing, nTail, &Rec, sizeof (Rec));
	CLFRingCopyIn (pRing, nTail + sizeof (Rec), pText, nLength);

	// The record becomes visible only once its bytes are: this release is
	// what makes a half-written record impossible for core 0 to read.
	__atomic_store_n (&pRing->nTail, nTail + nNeed, __ATOMIC_RELEASE);
}

// Say when a ring STARTS losing lines and when it STOPS, rather than once a
// pass: a ring is full precisely when the console cannot keep up, and a line
// per pass about it would spend the scarce thing describing its own scarcity.
static void CLFReportDrops (unsigned nCore)
{
	unsigned nLost = __atomic_exchange_n (&s_Ring[nCore].nDropped, 0U,
					      __ATOMIC_RELAXED);

	if (nLost != 0)
	{
		s_nDroppedTotal[nCore] += nLost;
		if (!s_bDropping[nCore])
		{
			s_bDropping[nCore] = TRUE;
			CLogger::Get ()->WriteNoAlloc ("fpclog", LogWarning,
				"a core's log ring is full and lines are being dropped");
		}
		return;
	}

	if (s_bDropping[nCore])
	{
		s_bDropping[nCore] = FALSE;
		CLogger::Get ()->WriteNoAlloc ("fpclog", LogWarning,
			"a core's log ring is keeping up again");
	}
}

void FPCCircle_LogDrain (void)
{
	if (CLFLogThisCore () != 0)
	{
		return;		// the console is core 0's, and so is this
	}

	// circle-libsdl2 carries the lines itself when it is in the image, and
	// drains them on its own servo. Nothing rings here then.
	if (SDL2Circle_LogBytes != 0)
	{
		return;
	}

	const u64 ulStarted = CTimer::GetClockTicks64 ();	// CLOCKHZ is 1 MHz
	unsigned nPrinted = 0;

	// WHERE A PASS STARTS, and why it moves. The bounded bite has to be
	// shared out, or the lowest-numbered core that keeps printing would
	// spend the whole budget every pass and the cores above it would never
	// be drained — silence that looks exactly like a core that has stopped.
	static unsigned s_nNextCore = 0;

	for (unsigned i = 0; i < CLF_LOG_CORES; i++)
	{
		const unsigned nCore = (s_nNextCore + i) % CLF_LOG_CORES;
		CLFLogRing *pRing = &s_Ring[nCore];

		for (;;)
		{
			if (nPrinted >= CLF_LOG_DRAIN_MAX_LINES
			    || CTimer::GetClockTicks64 () - ulStarted
			       >= CLF_LOG_DRAIN_MAX_US)
			{
				// Out of budget. The next pass starts at the core
				// AFTER this one, so a core that prints without
				// pause cannot keep every core above it silent.
				s_nNextCore = (nCore + 1) % CLF_LOG_CORES;
				return;
			}

			unsigned nHead = __atomic_load_n (&pRing->nHead,
							  __ATOMIC_RELAXED);
			unsigned nTail = __atomic_load_n (&pRing->nTail,
							  __ATOMIC_ACQUIRE);
			if (nHead == nTail)
			{
				break;
			}

			CLFLogRec Rec;
			CLFRingCopyOut (pRing, nHead, &Rec, sizeof (Rec));
			if (Rec.nLength > CLF_LOG_LINE_MAX)
			{
				Rec.nLength = CLF_LOG_LINE_MAX;
			}

			char Line[CLF_LOG_LINE_MAX + 1];
			CLFRingCopyOut (pRing, nHead + sizeof (Rec), Line,
					Rec.nLength);
			Line[Rec.nLength] = '\0';

			__atomic_store_n (&pRing->nHead,
					  nHead + sizeof (Rec) + Rec.nLength,
					  __ATOMIC_RELEASE);

			CLogger::Get ()->WriteNoAlloc (
				Rec.pFrom != 0 ? Rec.pFrom : FromPascal,
				LogNotice, Line);
			nPrinted++;
		}

		CLFReportDrops (nCore);
	}

	s_nNextCore = 0;
}

// ---------------------------------------------------------------------------
// One finished line, on its way out
// ---------------------------------------------------------------------------

static void CLFEmitLine (const char *pFrom, const char *pText, unsigned nLength)
{
	if (SDL2Circle_LogBytes != 0)
	{
		// The I/O surface takes the line and its newline, and carries it
		// off this core itself.
		SDL2Circle_LogBytes (pFrom, pText, nLength);
		SDL2Circle_LogBytes (pFrom, "\n", 1);
		return;
	}

	if (CLFLogThisCore () == 0)
	{
		// Core 0 owns the console, so its own lines go straight out.
		// That keeps the start-up log immediate, before any thread
		// exists to ring anything.
		CLogger::Get ()->WriteNoAlloc (pFrom, LogNotice, pText);
		return;
	}

	CLFRingPush (pFrom, pText, nLength);
}

// Assemble bytes into lines and publish each one as it completes.
static void CLFWriteBytes (const char *pFrom, const char *pBytes,
			   unsigned nLength)
{
	CLFLineBuffer *pBuf = &s_Line[CLFLogThisCore ()];
	pBuf->pFrom = pFrom;

	for (unsigned i = 0; i < nLength; i++)
	{
		char c = pBytes[i];

		if (c == '\n' || pBuf->nLength == CLF_LOG_LINE_MAX)
		{
			pBuf->Text[pBuf->nLength] = '\0';
			CLFEmitLine (pFrom, pBuf->Text, pBuf->nLength);
			pBuf->nLength = 0;

			if (c == '\n')
			{
				continue;
			}
		}

		if (c == '\r')
		{
			continue;
		}

		pBuf->Text[pBuf->nLength++] = c;
	}

	// Core 0 is the only core that can move anything off a ring, and it is
	// here often, so this is where the draining happens in an image that
	// has no other pump.
	FPCCircle_LogDrain ();
}

// ---------------------------------------------------------------------------
// What the Pascal side calls
// ---------------------------------------------------------------------------

void clf_write (const char *pBuffer, unsigned nLength)
{
	if (pBuffer == 0)
	{
		return;
	}

	CLFWriteBytes (FromPascal, pBuffer, nLength);
}

void clf_puts (const char *pString)
{
	if (pString == 0)
	{
		return;
	}

	unsigned nLength = 0;
	while (pString[nLength] != '\0')
	{
		nLength++;
	}

	CLFWriteBytes (FromPascal, pString, nLength);
}

// This library's own diagnostics, under a tag of their own so a reader can
// tell a message from the runtime apart from one the program printed.
void clf_log_error (const char *pMessage)
{
	if (pMessage == 0)
	{
		return;
	}

	unsigned nLength = 0;
	while (pMessage[nLength] != '\0')
	{
		nLength++;
	}

	CLFWriteBytes ("circle-libfpc", pMessage, nLength);
	CLFWriteBytes ("circle-libfpc", "\n", 1);
}
