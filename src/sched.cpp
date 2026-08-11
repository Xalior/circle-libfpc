//
// sched.cpp — what a Pascal thread is, and where it runs.
//
// A PASCAL THREAD IS NOT A CIRCLE TASK. Circle's cooperative scheduler is
// specified as belonging to core 0 alone, and a CTask registers itself with
// that scheduler while it is being constructed, so a task can only ever run
// where the scheduler is. Everything a Pascal thread needs — its identity, the
// runtime's threadvar block, the stack an exception frame walk is bounded by —
// hung off that task, and so it was all core 0's too.
//
// So a thread here is a record in the table below, and a core a host kernel
// has LENT runs it directly: no task, no scheduler, one thread at a time on
// that core. A host kernel starts its own secondary cores, decides what each
// one is for, and calls FPCCircle_ThreadCoreOffer on the ones it is willing to
// give away. This library never starts a core and never chooses one.
//
// WHAT FOLLOWS FROM HAVING NO SCHEDULER, and it is most of this file:
//
//   the wait      Every blocking loop here is one call in a loop, and nothing
//                 else: on core 0 it yields to Circle's scheduler, so whatever
//                 holds the thing being waited for can run; on any other core
//                 it is the processor's yield hint, because there is no
//                 scheduler there to hand the time to.
//
//   locks and     CMutex and CSynchronizationEvent are scheduler objects.
//   events        Acquiring one off core 0 blocks a task the calling core is
//                 not running. Both are rebuilt here from processor atomics
//                 and the wait above, so they exclude between cores.
//
//   storage       Per-thread storage lives in the thread's own record, found
//                 through the core that is running it. A core running no
//                 thread of ours — the one a host kernel called PASCALMAIN on
//                 — keeps its storage in a record of its own.
//
//   the stack     A thread runs on the lent core's own kernel stack, so the
//                 stack it is really on comes from Circle's per-core stack
//                 layout rather than from a task.
//
//   the heap      Free Pascal's heap manager walks a free list with no lock.
//                 That was safe only because a cooperative scheduler never
//                 interleaves it. Pascal on a second core ends that, so this
//                 file supplies the lock the Pascal side wraps it in.
//
// THE LIMITS, carried honestly:
//
//   - ONE THREAD PER LENT CORE at a time. A board lends what it can spare, so
//     the number of Pascal threads that can run at once is the number of cores
//     a host kernel gave away. A creation with none free is REFUSED and says
//     so; there is no core-0 fallback, because that fallback was the task.
//   - A WAIT OCCUPIES THE CORE IT WAITS ON. Off core 0 there is nothing to
//     sleep on, so a blocked thread is a spinning core.
//   - A TIMED WAIT IS UNTIMED. Every wait in this file runs until the thing it
//     waits for happens.
//
#include "sched.h"
#include <circle-libfpc/fpc.h>
#include <circle/sched/scheduler.h>
#include <circle/startup.h>
#include <circle/setjmp.h>
#include <circle/synchronize.h>
#include <circle/sysconfig.h>
#include <circle/new.h>

#ifdef ARM_ALLOW_MULTI_CORE
	#include <circle/multicore.h>
	#define CLF_MAX_CORES		CORES
#else
	#define CLF_MAX_CORES		1
#endif

#define CLF_MAX_THREADS		16

// ---------------------------------------------------------------------------
// The core the caller is on, and the one wait
// ---------------------------------------------------------------------------

static inline unsigned CLFThisCore (void)
{
#ifdef ARM_ALLOW_MULTI_CORE
	return CMultiCoreSupport::ThisCore () % CLF_MAX_CORES;
#else
	return 0;
#endif
}

// THE ONE WAIT. Blocking anywhere in this file is this call in a loop.
static void CLFWait (void)
{
	if (CLFThisCore () == 0)
	{
		// Core 0 is the only core that may carry a line off another
		// core's ring, and a wait is when it has the time to. See
		// src/log.cpp: a thread on a lent core prints into memory and
		// nothing else, because it owns no device.
		FPCCircle_LogDrain ();

		if (CScheduler::IsActive ())
		{
			// Core 0 has somewhere to hand the time to, so it does.
			// A host kernel's own tasks keep running while Pascal
			// waits.
			CScheduler::Get ()->Yield ();
			return;
		}
	}

	asm volatile ("yield" ::: "memory");
}

// ---------------------------------------------------------------------------
// What a thread is
// ---------------------------------------------------------------------------

struct CLFThread
{
	unsigned		 bUsed;		// the slot is spoken for
	unsigned		 bFinished;	// the body has returned
	long			 lResult;
	clf_thread_entry	 pEntry;
	void			*pParam;
	unsigned		 nCore;
	void			*pTLS;		// the runtime's threadvar block
};

// Static, and never freed. The handle Pascal holds is an index into this
// table, so a join or a release arriving long after the thread ended still
// lands on real memory.
static CLFThread s_Thread[CLF_MAX_THREADS];

// The thread each core is running, and what says that core is busy.
static CLFThread * volatile s_pRunning[CLF_MAX_CORES];

// Storage for a core that is running no thread of ours.
static void * volatile s_pCoreTLS[CLF_MAX_CORES];

// Cores a host kernel has lent, as a bitmask.
static volatile unsigned s_nCoresOffered = 0;

// One pending placement per core, because two cores may each be about to
// create a thread and neither should be able to take the other's placement.
static volatile unsigned s_nPinRequest[CLF_MAX_CORES];

// Where a lent core resumes when a thread ends through clf_thread_exit rather
// than by returning. A thread here is a plain call on the core's stack, so
// there is no task to terminate and the only way out is back to the loop that
// called it.
static jmp_buf s_ExitEnv[CLF_MAX_CORES];
static volatile unsigned s_bExitEnvValid[CLF_MAX_CORES];

static CLFThread *CLFCurrentThread (void)
{
	return (CLFThread *) __atomic_load_n (&s_pRunning[CLFThisCore ()],
					      __ATOMIC_ACQUIRE);
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------
//
// Never zero, on any core. A thread answers with its handle; a core running no
// thread of ours answers with a number past the end of the handle range, so
// the main line of execution has an identity of its own without ever looking
// like a thread that could be joined. Two lines of execution genuinely exist
// now, and a recursive lock has to be able to tell them apart.

unsigned long clf_thread_self (void)
{
	CLFThread *pThread = CLFCurrentThread ();
	if (pThread != 0)
	{
		return (unsigned long) (pThread - s_Thread) + 1;
	}

	return CLF_MAX_THREADS + CLFThisCore () + 1;
}

unsigned long clf_thread_core (void)
{
	return CLFThisCore ();
}

// ---------------------------------------------------------------------------
// Placement
// ---------------------------------------------------------------------------

unsigned long clf_cores_free (void)
{
	unsigned nFree = __atomic_load_n (&s_nCoresOffered, __ATOMIC_ACQUIRE);

	for (unsigned nCore = 0; nCore < CLF_MAX_CORES; nCore++)
	{
		if (__atomic_load_n (&s_pRunning[nCore], __ATOMIC_ACQUIRE) != 0)
		{
			nFree &= ~(1U << nCore);
		}
	}

	return nFree;
}

long clf_pin_next (unsigned long nCore)
{
	if (nCore == 0 || nCore >= CLF_MAX_CORES)
	{
		return -1;
	}

	if (!(clf_cores_free () & (1UL << nCore)))
	{
		return -1;
	}

	__atomic_store_n (&s_nPinRequest[CLFThisCore ()], (unsigned) nCore,
			  __ATOMIC_RELEASE);

	return 0;
}

// The placement this creation is to use: an explicit request if one is
// pending on this core, otherwise the lowest core that is free. Automatic
// placement is what makes the model reachable from Pascal at all — a thread is
// created inside the runtime, several call frames below any code that could
// have asked for a core.
static unsigned CLFTakePlacement (void)
{
	unsigned nCore = __atomic_exchange_n (&s_nPinRequest[CLFThisCore ()], 0U,
					      __ATOMIC_ACQ_REL);
	if (nCore != 0)
	{
		return nCore;
	}

	unsigned nFree = (unsigned) clf_cores_free ();
	for (nCore = 1; nCore < CLF_MAX_CORES; nCore++)
	{
		if (nFree & (1U << nCore))
		{
			return nCore;
		}
	}

	return 0;
}

// ---------------------------------------------------------------------------
// Creating, joining and ending a thread
// ---------------------------------------------------------------------------

unsigned long clf_thread_create (clf_thread_entry pEntry, void *pParam,
				 unsigned long nStackSize)
{
	(void) nStackSize;	// a thread runs on the lent core's own stack

	unsigned nCore = CLFTakePlacement ();
	if (nCore == 0)
	{
		clf_log_error ("no core is free for a Pascal thread. A host "
			       "kernel lends one with FPCCircle_ThreadCoreOffer.");
		return 0;
	}

	unsigned nSlot = CLF_MAX_THREADS;
	for (unsigned i = 0; i < CLF_MAX_THREADS; i++)
	{
		if (__atomic_exchange_n (&s_Thread[i].bUsed, 1U,
					 __ATOMIC_ACQ_REL) == 0)
		{
			nSlot = i;
			break;
		}
	}

	if (nSlot == CLF_MAX_THREADS)
	{
		clf_log_error ("no free thread slot");
		return 0;
	}

	CLFThread *pThread = &s_Thread[nSlot];
	pThread->bFinished = 0;
	pThread->lResult   = 0;
	pThread->pEntry    = pEntry;
	pThread->pParam    = pParam;
	pThread->nCore     = nCore;
	pThread->pTLS      = 0;

	CLFThread *pExpected = 0;
	if (!__atomic_compare_exchange_n (&s_pRunning[nCore], &pExpected, pThread,
					  false, __ATOMIC_RELEASE, __ATOMIC_RELAXED))
	{
		__atomic_store_n (&pThread->bUsed, 0U, __ATOMIC_RELEASE);
		clf_log_error ("the core asked for is already running a Pascal "
			       "thread");
		return 0;
	}

	// A lent core sleeps between threads, so it has to be woken.
	DataSyncBarrier ();
	asm volatile ("sev" ::: "memory");

	return (unsigned long) nSlot + 1;
}

long clf_thread_join (unsigned long hThread)
{
	if (hThread == 0 || hThread > CLF_MAX_THREADS)
	{
		return 0;
	}

	CLFThread *pThread = &s_Thread[hThread - 1];

	while (!__atomic_load_n (&pThread->bFinished, __ATOMIC_ACQUIRE))
	{
		CLFWait ();
	}

	return pThread->lResult;
}

void clf_thread_release (unsigned long hThread)
{
	if (hThread == 0 || hThread > CLF_MAX_THREADS)
	{
		return;
	}

	__atomic_store_n (&s_Thread[hThread - 1].bUsed, 0U, __ATOMIC_RELEASE);
}

void clf_thread_exit (void)
{
	unsigned nCore = CLFThisCore ();

	if (s_bExitEnvValid[nCore])
	{
		longjmp (s_ExitEnv[nCore], 1);
	}

	// Not a thread: this is the line of execution a host kernel called
	// PASCALMAIN on, and there is nothing here to return to.
	clf_log_error ("the main Pascal thread ended itself.");
	for (;;)
	{
		asm volatile ("wfi");
	}
}

void clf_yield (void)
{
	CLFWait ();
}

// ---------------------------------------------------------------------------
// Lending a core
// ---------------------------------------------------------------------------

void FPCCircle_ThreadCoreOffer (void)
{
	unsigned nCore = CLFThisCore ();

	if (nCore == 0)
	{
		// Core 0 is Circle's: its scheduler, its interrupts, its
		// devices. Parking it here would take the board down with it.
		clf_log_error ("core 0 cannot be lent to Pascal.");
		return;
	}

	__atomic_fetch_or (&s_nCoresOffered, 1U << nCore, __ATOMIC_RELEASE);

	for (;;)
	{
		CLFThread * volatile pThread =
			(CLFThread *) __atomic_load_n (&s_pRunning[nCore],
						       __ATOMIC_ACQUIRE);
		if (pThread == 0)
		{
			asm volatile ("wfe" ::: "memory");
			continue;
		}

		volatile long lResult = 0;

		if (setjmp (s_ExitEnv[nCore]) == 0)
		{
			s_bExitEnvValid[nCore] = 1;
			lResult = (*pThread->pEntry) (pThread->pParam);
		}
		// The other arm is a thread that ended through clf_thread_exit,
		// which has no result to give.

		s_bExitEnvValid[nCore] = 0;

		pThread->lResult = lResult;

		// Cleared only now: the slot is where per-thread storage is
		// found, so it has to outlive the body. Cleared BEFORE the
		// finished flag, so a joiner that immediately creates another
		// thread finds this core free.
		__atomic_store_n (&s_pRunning[nCore], (CLFThread *) 0,
				  __ATOMIC_RELEASE);
		__atomic_store_n (&pThread->bFinished, 1U, __ATOMIC_RELEASE);

		DataSyncBarrier ();
		asm volatile ("sev" ::: "memory");
	}
}

int FPCCircle_ThreadPinNext (unsigned nCore)
{
	return clf_pin_next (nCore) == 0 ? 0 : -1;
}

unsigned FPCCircle_ThreadCoresFree (void)
{
	return (unsigned) clf_cores_free ();
}

unsigned FPCCircle_ThisCore (void)
{
	return CLFThisCore ();
}

// ---------------------------------------------------------------------------
// Per-thread storage
// ---------------------------------------------------------------------------

void *clf_tls_get (void)
{
	CLFThread *pThread = CLFCurrentThread ();
	if (pThread != 0)
	{
		return pThread->pTLS;
	}

	return (void *) s_pCoreTLS[CLFThisCore ()];
}

void clf_tls_set (void *pBlock)
{
	CLFThread *pThread = CLFCurrentThread ();
	if (pThread != 0)
	{
		pThread->pTLS = pBlock;
		return;
	}

	s_pCoreTLS[CLFThisCore ()] = pBlock;
}

// ---------------------------------------------------------------------------
// The stack the caller is really on
// ---------------------------------------------------------------------------

unsigned long clf_stacktop (void)
{
	// On a lent core the answer is the core's own kernel stack. Circle's
	// scheduler replaces GetCurrentStack with the CURRENT TASK's stack,
	// which off core 0 is a question about a different core entirely.
	if (CLFThisCore () != 0)
	{
		return (unsigned long) __GetCurrentStackNoWeak ().Top;
	}

	return (unsigned long) GetCurrentStack ().Top;
}

unsigned long clf_stacksize (void)
{
	if (CLFThisCore () != 0)
	{
		return (unsigned long) __GetCurrentStackNoWeak ().Size;
	}

	return (unsigned long) GetCurrentStack ().Size;
}

// ---------------------------------------------------------------------------
// Locks
// ---------------------------------------------------------------------------
//
// Recursive, and owned by an IDENTITY rather than by a scheduler task, so the
// owner does not move under a holder that is simply getting on with its work.
// Free Pascal's critical section is recursive on the platforms its code was
// written against, so it is recursive here.

struct CLFMutex
{
	unsigned long	nOwner;		// 0 when free
	unsigned	nCount;		// recursion depth
};

static void CLFMutexAcquire (CLFMutex *pMutex)
{
	const unsigned long nMe = clf_thread_self ();

	if (__atomic_load_n (&pMutex->nOwner, __ATOMIC_ACQUIRE) == nMe)
	{
		pMutex->nCount++;
		return;
	}

	unsigned long nExpected = 0;
	while (!__atomic_compare_exchange_n (&pMutex->nOwner, &nExpected, nMe,
					     true, __ATOMIC_ACQUIRE,
					     __ATOMIC_RELAXED))
	{
		nExpected = 0;
		CLFWait ();
	}

	pMutex->nCount = 1;
}

static bool CLFMutexTryAcquire (CLFMutex *pMutex)
{
	const unsigned long nMe = clf_thread_self ();

	if (__atomic_load_n (&pMutex->nOwner, __ATOMIC_ACQUIRE) == nMe)
	{
		pMutex->nCount++;
		return true;
	}

	unsigned long nExpected = 0;
	if (!__atomic_compare_exchange_n (&pMutex->nOwner, &nExpected, nMe,
					  false, __ATOMIC_ACQUIRE,
					  __ATOMIC_RELAXED))
	{
		return false;
	}

	pMutex->nCount = 1;
	return true;
}

static void CLFMutexRelease (CLFMutex *pMutex)
{
	// Releasing a lock this line of execution does not hold is the caller's
	// error, and it is not diagnosed: stopping the board to report it is
	// what the scheduler primitive this replaces did.
	if (pMutex->nCount > 0 && --pMutex->nCount == 0)
	{
		__atomic_store_n (&pMutex->nOwner, 0UL, __ATOMIC_RELEASE);
	}
}

void *clf_mutex_create (void)
{
	CLFMutex *pMutex = new CLFMutex;
	pMutex->nOwner = 0;
	pMutex->nCount = 0;

	return pMutex;
}

void clf_mutex_destroy (void *pMutex)
{
	delete (CLFMutex *) pMutex;
}

void clf_mutex_acquire (void *pMutex)
{
	CLFMutexAcquire ((CLFMutex *) pMutex);
}

long clf_mutex_try (void *pMutex)
{
	return CLFMutexTryAcquire ((CLFMutex *) pMutex) ? 1 : 0;
}

void clf_mutex_release (void *pMutex)
{
	CLFMutexRelease ((CLFMutex *) pMutex);
}

// The Free Pascal heap's lock. Static, so taking it allocates nothing — the
// one lock in the system that cannot be allowed to need the heap.
static CLFMutex s_HeapMutex = { 0, 0 };

void clf_heap_lock (void)
{
	CLFMutexAcquire (&s_HeapMutex);
}

void clf_heap_unlock (void)
{
	CLFMutexRelease (&s_HeapMutex);
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
//
// Manual reset, which is what the scheduler object these replace did: a wait
// on an event that is already set returns at once, and a set stays set until
// something clears it.

struct CLFEvent
{
	unsigned bState;
};

void *clf_event_create (void)
{
	CLFEvent *pEvent = new CLFEvent;
	pEvent->bState = 0;

	return pEvent;
}

void clf_event_destroy (void *pEvent)
{
	delete (CLFEvent *) pEvent;
}

void clf_event_set (void *pEvent)
{
	__atomic_store_n (&((CLFEvent *) pEvent)->bState, 1U, __ATOMIC_RELEASE);
	DataSyncBarrier ();
	asm volatile ("sev" ::: "memory");
}

void clf_event_clear (void *pEvent)
{
	__atomic_store_n (&((CLFEvent *) pEvent)->bState, 0U, __ATOMIC_RELEASE);
}

void clf_event_wait (void *pEvent)
{
	while (!__atomic_load_n (&((CLFEvent *) pEvent)->bState, __ATOMIC_ACQUIRE))
	{
		CLFWait ();
	}
}
