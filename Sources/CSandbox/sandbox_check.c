#include "CSandbox.h"

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
// Exported by libsystem_sandbox. Set in the filter type so a "denied" answer isn't logged as a violation.
extern const int SANDBOX_CHECK_NO_REPORT;

int pxr_sandbox_check(pid_t pid, const char *operation, int filter_type, const char *argument) {
    int type = filter_type | SANDBOX_CHECK_NO_REPORT;
    if (filter_type == 0) return sandbox_check(pid, operation, type);
    return sandbox_check(pid, operation, type, argument);
}
