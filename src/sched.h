//
// sched.h
//
// The C surface the Free Pascal thread manager in rtl/clfthreads.pp calls.
// Circle is C++, Free Pascal calls C, so nothing C++ crosses here.
//
// This is internal to circle-libfpc. It deals in a thread entry point, a
// handle, a lock and an event, and it knows nothing about Free Pascal. What a
// HOST KERNEL calls is in include/circle-libfpc/fpc.h instead.
//
// A Pascal thread is not a Circle task. It is a record in a table this file
// owns, run directly by a core a host kernel has lent — see
// docs/THREADING.md.
//
#ifndef _circle_libfpc_sched_h
#define _circle_libfpc_sched_h

#ifdef __cplusplus
extern "C" {
#endif

typedef long (*clf_thread_entry) (void *pParam);

// Threads. The handle is an index into a table this file owns; the record it
// names outlives the thread's execution, so a join arriving after the thread
// has ended still finds its result.
//
// nStackSize is accepted and ignored: a thread runs on the lent core's own
// kernel stack, whose size is the world's KERNEL_STACK_SIZE.
unsigned long clf_thread_create (clf_thread_entry pEntry, void *pParam,
				 unsigned long nStackSize);
long          clf_thread_join (unsigned long hThread);
void          clf_thread_release (unsigned long hThread);
unsigned long clf_thread_self (void);		// never 0; see sched.cpp
unsigned long clf_thread_core (void);		// the core the caller runs on
void          clf_thread_exit (void);		// does not return
void          clf_yield (void);

// Placement. A host kernel has its own names for these in fpc.h; both reach
// the same request.
long          clf_pin_next (unsigned long nCore);	// 0 placed, -1 refused
unsigned long clf_cores_free (void);			// bitmask

// Per-thread storage for the runtime's threadvars. Kept in the thread's own
// record, and in a per-core record for a core running no thread of ours — the
// core a host kernel called PASCALMAIN on.
void *clf_tls_get (void);
void  clf_tls_set (void *pBlock);

// The stack the calling line of execution is really running on, from Circle's
// own idea of the current stack. This is not what System.StackTop reports —
// see docs/THREADING.md.
unsigned long clf_stacktop (void);
unsigned long clf_stacksize (void);

// Locks and events, for critical sections and RTL events. Neither is a Circle
// scheduler object: both are used from cores that have no scheduler.
void *clf_mutex_create (void);
void  clf_mutex_destroy (void *pMutex);
void  clf_mutex_acquire (void *pMutex);
long  clf_mutex_try (void *pMutex);
void  clf_mutex_release (void *pMutex);

void *clf_event_create (void);
void  clf_event_destroy (void *pEvent);
void  clf_event_set (void *pEvent);
void  clf_event_clear (void *pEvent);
void  clf_event_wait (void *pEvent);

// This library's own diagnostics. It owns no device; see src/log.cpp for
// where a line actually goes.
void clf_log_error (const char *pMessage);

// The Free Pascal heap, which is not Circle's and carries no lock of its own.
// Recursive, so a memory manager handler that reaches another through the
// record cannot lock against itself.
void clf_heap_lock (void);
void clf_heap_unlock (void);

#ifdef __cplusplus
}
#endif

#endif
