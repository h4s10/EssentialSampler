// Make assertion/abort failures terminate CI tests instead of opening modal CRT
// or Windows Error Reporting dialogs on the runner's desktop.
#include <windows.h>
#include <cstdlib>
#include <crtdbg.h>
namespace {
struct Setup {
    Setup() {
        SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
        _set_error_mode(_OUT_TO_STDERR);
        _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
    }
} setup;
}
