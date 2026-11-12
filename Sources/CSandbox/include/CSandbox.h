#pragma once
#include <sys/types.h>

/// sandbox_check(pid, operation, filter_type | SANDBOX_CHECK_NO_REPORT, argument).
/// sandbox_check is variadic, and on arm64 variadic arguments go on the stack, so Swift can't call it
/// through a plain function pointer: this shim makes the call from C.
/// `argument` is ignored when `filter_type` is 0 (no filter).
/// Returns 0 = allowed, 1 = denied, -1 = error (unknown operation, bad filter, no such process).
int pxr_sandbox_check(pid_t pid, const char *operation, int filter_type, const char *argument);
