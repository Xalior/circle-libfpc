unit clfthreads;

{ A Free Pascal thread manager, and the memory manager lock that goes with it.

  The RTL does not call Circle. It calls CurrentTM, a record of function
  pointers, and this unit fills that record with routines that forward to the
  C surface in src/sched.cpp.

  A PASCAL THREAD RUNS ON A CORE OF ITS OWN. It is not a Circle task: a task
  belongs to the scheduler on core 0 and runs nowhere else. A host kernel
  starts its secondary cores and lends one or more to Pascal, and a thread
  created here runs on one of them, alone, for as long as it lives. With no
  core lent there are no threads at all -- BeginThread returns 0 and the
  console says why. See docs/THREADING.md.

  Two things are worth knowing before reading further.

  Enabling the THREADING feature in the RTL adds NOTHING to the
  undefined-symbol contract. A program that uses threadvars, critical
  sections, RTL events, BeginThread and WaitForThreadTerminate links leaving
  the same symbols as one that does none of it. The cost is entirely at run
  time: until SetThreadManager is called, CurrentTM is the RTL's
  NoThreadManager, whose every handler reports a runtime error. So a link
  succeeding proves nothing about threading, and this unit's initialization
  section is what makes the difference.

  THE HEAP NEEDS A LOCK NOW, and this unit installs it. heapmgr walks a free
  list with no lock of its own, which was safe only while every line of Pascal
  in the image ran on one core. Two cores allocating at once is exactly what
  this thread model makes ordinary, so the memory manager is wrapped here: the
  six handlers that touch the free list take a recursive lock, and the rest of
  the record is passed through untouched. }

{$mode objfpc}
{$H-}

interface

procedure CLFInstallThreadManager;

{ Reports the top of the stack the CALLING thread is really running on, as
  Circle knows it. This is not what System.StackTop returns -- see the note in
  the implementation. }
function CLFRealStackTop: PtrUInt;
function CLFRealStackSize: PtrUInt;

{ Where the caller is running. }
function CLFThisCore: longint;

{ Place the NEXT thread this core creates on a named core. True when the
  request is accepted; false when that core is not one a thread can run on, or
  is not free. A creation with no request pending takes the lowest free lent
  core, which is what a thread created inside the RTL -- TThread, for one --
  gets without asking. }
function CLFPinNextThread(ACore: longint): boolean;

{ The cores that are free right now, as a bitmask. A core that was never lent,
  and one already running a thread, are not in it. }
function CLFCoresFree: longint;

implementation

{ ---- the host kernel's C surface -------------------------------------- }

function  clf_thread_create(entry, param: pointer; stacksize: QWord): QWord; cdecl; external name 'clf_thread_create';
function  clf_thread_join(h: QWord): PtrInt; cdecl; external name 'clf_thread_join';
procedure clf_thread_release(h: QWord); cdecl; external name 'clf_thread_release';
function  clf_thread_self: QWord; cdecl; external name 'clf_thread_self';
function  clf_thread_core: QWord; cdecl; external name 'clf_thread_core';
procedure clf_thread_exit; cdecl; external name 'clf_thread_exit';
procedure clf_yield; cdecl; external name 'clf_yield';
function  clf_pin_next(core: QWord): PtrInt; cdecl; external name 'clf_pin_next';
function  clf_cores_free: QWord; cdecl; external name 'clf_cores_free';
procedure clf_heap_lock; cdecl; external name 'clf_heap_lock';
procedure clf_heap_unlock; cdecl; external name 'clf_heap_unlock';
function  clf_tls_get: pointer; cdecl; external name 'clf_tls_get';
procedure clf_tls_set(p: pointer); cdecl; external name 'clf_tls_set';
function  clf_stacktop: PtrUInt; cdecl; external name 'clf_stacktop';
function  clf_stacksize: PtrUInt; cdecl; external name 'clf_stacksize';
function  clf_mutex_create: pointer; cdecl; external name 'clf_mutex_create';
procedure clf_mutex_destroy(m: pointer); cdecl; external name 'clf_mutex_destroy';
procedure clf_mutex_acquire(m: pointer); cdecl; external name 'clf_mutex_acquire';
function  clf_mutex_try(m: pointer): PtrInt; cdecl; external name 'clf_mutex_try';
procedure clf_mutex_release(m: pointer); cdecl; external name 'clf_mutex_release';
function  clf_event_create: pointer; cdecl; external name 'clf_event_create';
procedure clf_event_destroy(e: pointer); cdecl; external name 'clf_event_destroy';
procedure clf_event_set(e: pointer); cdecl; external name 'clf_event_set';
procedure clf_event_clear(e: pointer); cdecl; external name 'clf_event_clear';
procedure clf_event_wait(e: pointer); cdecl; external name 'clf_event_wait';

type
  PCLFThreadInfo = ^TCLFThreadInfo;
  TCLFThreadInfo = record
    Func   : TThreadFunc;
    Param  : pointer;
    StkLen : PtrUInt;
  end;

var
  ThreadVarBlockSize : PtrUInt = 0;
  ThreadVarsInited   : boolean = false;

function CLFRealStackTop: PtrUInt;
begin
  Result := clf_stacktop;
end;

function CLFRealStackSize: PtrUInt;
begin
  Result := clf_stacksize;
end;

function CLFThisCore: longint;
begin
  Result := longint(clf_thread_core);
end;

function CLFPinNextThread(ACore: longint): boolean;
begin
  Result := clf_pin_next(QWord(ACore)) = 0;
end;

function CLFCoresFree: longint;
begin
  Result := longint(clf_cores_free);
end;

{ ---- the heap lock ----------------------------------------------------

  heapmgr's free list has no lock, and two cores allocating at once is what
  this thread model makes ordinary. The six handlers that touch the list are
  wrapped; everything else in the record is the one heapmgr installed.

  The lock is recursive and it lives in C, in static storage, so taking it
  allocates nothing -- this is the one lock in the system that must never need
  the heap it protects. }

var
  InnerMM: TMemoryManager;

function CLFGetMem(Size: PtrUInt): pointer;
begin
  clf_heap_lock;
  Result := InnerMM.GetMem(Size);
  clf_heap_unlock;
end;

function CLFFreeMem(p: pointer): PtrUInt;
begin
  clf_heap_lock;
  Result := InnerMM.FreeMem(p);
  clf_heap_unlock;
end;

function CLFFreeMemSize(p: pointer; Size: PtrUInt): PtrUInt;
begin
  clf_heap_lock;
  Result := InnerMM.FreeMemSize(p, Size);
  clf_heap_unlock;
end;

function CLFAllocMem(Size: PtrUInt): pointer;
begin
  clf_heap_lock;
  Result := InnerMM.AllocMem(Size);
  clf_heap_unlock;
end;

function CLFReAllocMem(var p: pointer; Size: PtrUInt): pointer;
begin
  clf_heap_lock;
  Result := InnerMM.ReAllocMem(p, Size);
  clf_heap_unlock;
end;

function CLFMemSize(p: pointer): PtrUInt;
begin
  { A read, but of a header another core may be coalescing, so it takes the
    lock like the rest. }
  clf_heap_lock;
  Result := InnerMM.MemSize(p);
  clf_heap_unlock;
end;

procedure CLFInstallHeapLock;
var
  MM: TMemoryManager;
begin
  GetMemoryManager(InnerMM);

  { Nothing has installed a memory manager yet. Wrapping an all-nil record
    would replace a failure that names itself with one that does not, so this
    leaves it alone and the first allocation reports as it always did. }
  if not Assigned(InnerMM.GetMem) then
    exit;

  MM := InnerMM;
  MM.GetMem      := @CLFGetMem;
  MM.FreeMem     := @CLFFreeMem;
  MM.FreeMemSize := @CLFFreeMemSize;
  MM.AllocMem    := @CLFAllocMem;
  MM.ReAllocMem  := @CLFReAllocMem;
  MM.MemSize     := @CLFMemSize;
  SetMemoryManager(MM);
end;

{ ---- threadvars -------------------------------------------------------

  The runtime keeps every threadvar of every unit in one flat block per
  thread. InitThreadVar hands out offsets into it, AllocateThreadVars makes
  the block, and RelocateThreadVar turns an offset into an address. The block
  is kept in the thread's own record, found through the core that is running
  it; a core running no thread of ours -- the one a host kernel called
  PASCALMAIN on -- keeps its block in a record of its own, so the main thread
  needs no special case.

  This must not allocate through anything that itself uses a threadvar, or
  the first threadvar access would recurse forever. heapmgr declares none,
  and the lock this unit wraps it in declares none either, which is what makes
  GetMem safe to call from here. }

procedure CLFInitThreadVar(var offset: dword; size: dword);
begin
  offset := ThreadVarBlockSize;
  Inc(ThreadVarBlockSize, (size + 15) and not PtrUInt(15));
end;

procedure CLFAllocateThreadVars;
var
  p: pointer;
begin
  if ThreadVarBlockSize = 0 then
    ThreadVarBlockSize := 16;
  p := GetMem(ThreadVarBlockSize);
  if p <> nil then
    FillChar(p^, ThreadVarBlockSize, 0);
  clf_tls_set(p);
end;

function CLFRelocateThreadVar(offset: dword): pointer;
var
  p: pointer;
begin
  p := clf_tls_get;
  if p = nil then
  begin
    { A thread the runtime did not start -- or the main thread before
      InitThreadVars got to it. Give it a block rather than return a bad
      address. }
    CLFAllocateThreadVars;
    p := clf_tls_get;
  end;
  Result := pointer(PtrUInt(p) + offset);
end;

procedure CLFReleaseThreadVars;
var
  p: pointer;
begin
  p := clf_tls_get;
  if p <> nil then
  begin
    clf_tls_set(nil);
    FreeMem(p);
  end;
end;

{ ---- threads ---------------------------------------------------------- }

function CLFThreadTrampoline(param: pointer): PtrInt; cdecl;
var
  ti: TCLFThreadInfo;
begin
  { First, before anything else: exception handling and IO both live in
    threadvars, so the block has to exist before the runtime is entered. }
  CLFAllocateThreadVars;

  ti := PCLFThreadInfo(param)^;
  FreeMem(param);

  InitThread(ti.StkLen);

  Result := ti.Func(ti.Param);

  DoneThread;
end;

function CLFBeginThread(sa: pointer; stacksize: PtrUInt; ThreadFunction: TThreadFunc;
                        p: pointer; creationFlags: dword; var ThreadId: TThreadID): TThreadID;
var
  ti: PCLFThreadInfo;
  h : QWord;
begin
  if not ThreadVarsInited then
  begin
    { Assigns every threadvar its offset, makes the main thread's block, and
      copies the single-threaded values into it. After this call every
      threadvar access in the program goes through CLFRelocateThreadVar. }
    InitThreadVars(@CLFRelocateThreadVar);
    ThreadVarsInited := true;
  end;

  IsMultiThread := true;

  ti := GetMem(SizeOf(TCLFThreadInfo));
  ti^.Func := ThreadFunction;
  ti^.Param := p;
  ti^.StkLen := stacksize;

  h := clf_thread_create(@CLFThreadTrampoline, ti, stacksize);
  if h = 0 then
    FreeMem(ti);

  ThreadId := TThreadID(h);
  Result := TThreadID(h);
end;

procedure CLFEndThread(ExitCode: dword);
begin
  DoneThread;
  clf_thread_exit;
end;

function CLFWaitForThreadTerminate(threadHandle: TThreadID; TimeoutMs: longint): dword;
begin
  { TimeoutMs is ignored: this waits without limit. Circle can wait with a
    timeout, but a join that silently returns early would be worse than one
    that is honest about only having one behaviour. }
  clf_thread_join(QWord(threadHandle));
  clf_thread_release(QWord(threadHandle));
  Result := 0;
end;

procedure CLFThreadSwitch;
begin
  clf_yield;
end;

function CLFGetCurrentThreadId: TThreadID;
begin
  Result := TThreadID(clf_thread_self);
end;

{ A thread here is a line of execution on a core of its own, with nothing
  above it to stop, restart or rank it: there is no suspend, no kill and no
  priority. These exist because the record's fields must not be nil -- the
  runtime calls them without checking. They do nothing and say so by their
  return value. }

function CLFThreadNotSupported(threadHandle: TThreadID): dword;
begin
  Result := dword(-1);
end;

function CLFSetPriorityNotSupported(threadHandle: TThreadID; Prio: longint): boolean;
begin
  Result := false;
end;

function CLFGetPriorityNotSupported(threadHandle: TThreadID): longint;
begin
  Result := 0;
end;

procedure CLFSetDebugNameA(threadHandle: TThreadID; const ThreadName: AnsiString);
begin
end;

{ ---- critical sections -------------------------------------------------

  TRTLCriticalSection is a record the runtime never looks inside on this
  target, so its first pointer-sized field carries the lock. }

type
  PCLFSection = ^TCLFSection;
  TCLFSection = record
    Mutex: pointer;
  end;

procedure CLFInitCriticalSection(var cs);
begin
  PCLFSection(@cs)^.Mutex := clf_mutex_create;
end;

procedure CLFDoneCriticalSection(var cs);
begin
  if PCLFSection(@cs)^.Mutex <> nil then
  begin
    clf_mutex_destroy(PCLFSection(@cs)^.Mutex);
    PCLFSection(@cs)^.Mutex := nil;
  end;
end;

procedure CLFEnterCriticalSection(var cs);
begin
  clf_mutex_acquire(PCLFSection(@cs)^.Mutex);
end;

function CLFTryEnterCriticalSection(var cs): longint;
begin
  Result := longint(clf_mutex_try(PCLFSection(@cs)^.Mutex));
end;

procedure CLFLeaveCriticalSection(var cs);
begin
  clf_mutex_release(PCLFSection(@cs)^.Mutex);
end;

{ ---- events ----------------------------------------------------------- }

function CLFRTLEventCreate: PRTLEvent;
begin
  Result := PRTLEvent(clf_event_create);
end;

procedure CLFRTLEventDestroy(AEvent: PRTLEvent);
begin
  clf_event_destroy(pointer(AEvent));
end;

procedure CLFRTLEventSetEvent(AEvent: PRTLEvent);
begin
  clf_event_set(pointer(AEvent));
end;

procedure CLFRTLEventResetEvent(AEvent: PRTLEvent);
begin
  clf_event_clear(pointer(AEvent));
end;

procedure CLFRTLEventWaitFor(AEvent: PRTLEvent);
begin
  clf_event_wait(pointer(AEvent));
end;

procedure CLFRTLEventWaitForTimeout(AEvent: PRTLEvent; timeout: longint);
begin
  clf_event_wait(pointer(AEvent));
end;

function CLFBasicEventCreate(EventAttributes: pointer; AManualReset, InitialState: boolean;
                             const Name: AnsiString): PEventState;
begin
  Result := PEventState(clf_event_create);
  if InitialState then
    clf_event_set(pointer(Result));
end;

procedure CLFBasicEventDestroy(state: PEventState);
begin
  clf_event_destroy(pointer(state));
end;

procedure CLFBasicEventResetEvent(state: PEventState);
begin
  clf_event_clear(pointer(state));
end;

procedure CLFBasicEventSetEvent(state: PEventState);
begin
  clf_event_set(pointer(state));
end;

function CLFBasicEventWaitFor(timeout: cardinal; state: PEventState; FUseComWait: boolean = false): longint;
begin
  clf_event_wait(pointer(state));
  Result := 0;
end;

{ ---- installation ------------------------------------------------------ }

var
  CLFThreadManager: TThreadManager;

procedure CLFInstallThreadManager;
begin
  FillChar(CLFThreadManager, SizeOf(CLFThreadManager), 0);
  with CLFThreadManager do
  begin
    InitManager             := nil;
    DoneManager             := nil;
    BeginThread             := @CLFBeginThread;
    EndThread               := @CLFEndThread;
    SuspendThread           := @CLFThreadNotSupported;
    ResumeThread            := @CLFThreadNotSupported;
    KillThread              := @CLFThreadNotSupported;
    CloseThread             := @CLFThreadNotSupported;
    ThreadSwitch            := @CLFThreadSwitch;
    WaitForThreadTerminate  := @CLFWaitForThreadTerminate;
    ThreadSetPriority       := @CLFSetPriorityNotSupported;
    ThreadGetPriority       := @CLFGetPriorityNotSupported;
    GetCurrentThreadId      := @CLFGetCurrentThreadId;
    { There is no SetThreadDebugNameU field on this target: the record
      carries it only under FPC_HAS_FEATURE_UNICODESTRINGS, and the embedded
      RTL enables WIDESTRINGS without it. }
    SetThreadDebugNameA     := @CLFSetDebugNameA;
    InitCriticalSection     := @CLFInitCriticalSection;
    DoneCriticalSection     := @CLFDoneCriticalSection;
    EnterCriticalSection    := @CLFEnterCriticalSection;
    TryEnterCriticalSection := @CLFTryEnterCriticalSection;
    LeaveCriticalSection    := @CLFLeaveCriticalSection;
    InitThreadVar           := @CLFInitThreadVar;
    RelocateThreadVar       := @CLFRelocateThreadVar;
    AllocateThreadVars      := @CLFAllocateThreadVars;
    ReleaseThreadVars       := @CLFReleaseThreadVars;
    BasicEventCreate        := @CLFBasicEventCreate;
    BasicEventDestroy       := @CLFBasicEventDestroy;
    BasicEventResetEvent    := @CLFBasicEventResetEvent;
    BasicEventSetEvent      := @CLFBasicEventSetEvent;
    BasicEventWaitFor       := @CLFBasicEventWaitFor;
    RTLEventCreate          := @CLFRTLEventCreate;
    RTLEventDestroy         := @CLFRTLEventDestroy;
    RTLEventSetEvent        := @CLFRTLEventSetEvent;
    RTLEventResetEvent      := @CLFRTLEventResetEvent;
    RTLEventWaitFor         := @CLFRTLEventWaitFor;
    RTLEventWaitForTimeout  := @CLFRTLEventWaitForTimeout;
  end;
  SetThreadManager(CLFThreadManager);
end;

initialization
  { The heap lock first: the thread manager's own handlers allocate, and a
    thread may be created before the next line of the program runs. This is
    also why circlefpc names heapmgr ahead of this unit -- unit initialization
    runs in the order the uses clause gives, so the manager being wrapped here
    is already installed. }
  CLFInstallHeapLock;
  CLFInstallThreadManager;

end.
