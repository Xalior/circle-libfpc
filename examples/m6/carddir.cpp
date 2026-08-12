//
// carddir.cpp — the host kernel's own walk of a directory on the card.
//
// WHY THIS IS A FILE OF ITS OWN, AND NOT PART OF kernel.cpp. FatFs declares a
// type called DIR, and so does the C library's <dirent.h>. The kernel needs
// FatFs's own header for the FATFS object it mounts the card with, so those
// two headers can never meet in one translation unit. The directory walk
// therefore lives here, where <dirent.h> is the only one of the two present.
//
// WHAT IT IS FOR. M6's Pascal program reports what its FindFirst found. That
// report came out of the layer under test, so it is checked against a walk
// made here — on the core that owns the card, with the C library's own
// opendir and readdir, and with the names matched by hand rather than by a
// pattern, because a pattern matcher is one of the things being checked.
//
#include <dirent.h>
#include <string.h>

// Walk aDir and count the names that begin with aPrefix and end with aSuffix.
//
// The total number of entries goes into *pEntries, and every matching name is
// handed to pReport as it is found so that the caller can print it. The
// result is how many matched, or -1 when the directory could not be opened.
extern "C" int M6CountMatchingNames(const char *pDir,
                                    const char *pPrefix,
                                    const char *pSuffix,
                                    int *pEntries,
                                    void (*pReport)(const char *pName))
{
    if (pEntries != 0)
    {
        *pEntries = 0;
    }

    DIR *pHandle = opendir(pDir);
    if (pHandle == 0)
    {
        return -1;
    }

    const size_t nPre = strlen(pPrefix);
    const size_t nSuf = strlen(pSuffix);

    int nMatched = 0;
    struct dirent *pEntry;

    while ((pEntry = readdir(pHandle)) != 0)
    {
        if (pEntries != 0)
        {
            (*pEntries)++;
        }

        const size_t nLen = strlen(pEntry->d_name);

        if (nLen > nPre + nSuf &&
            strncmp(pEntry->d_name, pPrefix, nPre) == 0 &&
            strcmp(pEntry->d_name + nLen - nSuf, pSuffix) == 0)
        {
            nMatched++;
            if (pReport != 0)
            {
                pReport(pEntry->d_name);
            }
        }
    }

    closedir(pHandle);
    return nMatched;
}
