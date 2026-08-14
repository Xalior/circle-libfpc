//
// main.cpp — classic Circle kernel entry.
//
// The Pascal program's own C entry is renamed out of the way when it is
// compiled (fpc-app.mk, -XM), because Free Pascal calls it `main` too and
// Circle's start-up calls this one.
//
#include "kernel.h"
#include <circle/startup.h>

int main(void)
{
    CKernel Kernel;
    if (!Kernel.Initialize())
    {
        halt();
        return EXIT_HALT;
    }

    TShutdownMode ShutdownMode = Kernel.Run();

    switch (ShutdownMode)
    {
    case ShutdownReboot:
        reboot();
        return EXIT_REBOOT;

    case ShutdownHalt:
    default:
        halt();
        return EXIT_HALT;
    }
}
