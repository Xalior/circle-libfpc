//
// kernel.h
//
// Host kernel for circle-libfpc's minblock example: the smallest image that
// demonstrates the heap-manager defect described in minblock.pp.
//
// SINGLE CORE, no threads, no scheduler, no lent core, no packages. The defect
// is in the allocator's own arithmetic and needs none of that, and leaving it
// all out means nobody reading the result has to wonder whether concurrency
// was involved.
//
// Serial only. The kernel carries a CLogger because that is where everything
// the library prints ends up, and a CExceptionHandler because without one
// Circle's AArch64 exception stub calls CExceptionHandler::Get(), asserts, and
// with asserts compiled out dereferences the null it returns — answering a
// fault with a second fault and stopping in silence. This image is expected to
// fault, so being able to report the fault is the point.
//
#ifndef _kernel_h
#define _kernel_h

#include <circle/devicenameservice.h>
#include <circle/serial.h>
#include <circle/logger.h>
#include <circle/exceptionhandler.h>
#include <circle/timer.h>
#include <circle/types.h>

enum TShutdownMode
{
	ShutdownNone,
	ShutdownHalt,
	ShutdownReboot
};

class CKernel
{
public:
	CKernel (void);
	~CKernel (void);

	boolean Initialize (void);

	TShutdownMode Run (void);

private:
	// Do not change this order. CSerialDevice::Initialize registers itself
	// with the device name service, so that must exist first.
	CDeviceNameService	m_DeviceNameService;

	// Polling driver: the serial output itself needs no IRQ.
	CSerialDevice		m_Serial;

	CTimer			m_Timer;
	CLogger			m_Logger;
	CExceptionHandler	m_ExceptionHandler;
};

#endif
