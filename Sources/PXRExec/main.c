// pxr-exec: what posix_spawn can't set (resource limits, umask, nice, I/O policy, background priority, a sandbox
// profile), set in the process itself and then exec'd away, so the program keeps this process's pid. Proc X-Ray's
// Launcher starts it (suspended when tracing, so the trace begins with these few calls), as the app's child or as
// the helper's.
//
//   pxr-exec [-r NAME=soft:hard]… [-u umask] [-n nice] [-b] [-i iopolicy] [-S profile] -- path argv0 [args…]
//
// NAME: cpu fsize data stack core as rss memlock nproc nofile. soft/hard: a number, "inf", or empty to keep the
// current value. -S: an SBPL profile's text, applied with sandbox_init. Exits 127 with a message on stderr when a
// setting fails, without running the program.
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

int sandbox_init(const char *profile, uint64_t flags, char **errorbuf);
void sandbox_free_error(char *errorbuf);

static void fail(const char *what, const char *detail) {
    fprintf(stderr, "pxr-exec: %s%s%s\n", what, detail ? ": " : "", detail ? detail : "");
    exit(127);
}

static int resource(const char *name) {
    static const struct { const char *name; int res; } table[] = {
        {"cpu", RLIMIT_CPU}, {"fsize", RLIMIT_FSIZE}, {"data", RLIMIT_DATA}, {"stack", RLIMIT_STACK},
        {"core", RLIMIT_CORE}, {"as", RLIMIT_AS}, {"rss", RLIMIT_RSS}, {"memlock", RLIMIT_MEMLOCK},
        {"nproc", RLIMIT_NPROC}, {"nofile", RLIMIT_NOFILE},
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
        if (!strcmp(table[i].name, name)) return table[i].res;
    return -1;
}

// "" keeps `current`; "inf" is RLIM_INFINITY.
static rlim_t limitValue(const char *s, size_t n, rlim_t current, const char *arg) {
    if (n == 0) return current;
    if (n == 3 && !strncmp(s, "inf", 3)) return RLIM_INFINITY;
    char buf[32];
    if (n >= sizeof buf) fail("bad limit", arg);
    memcpy(buf, s, n); buf[n] = 0;
    char *end;
    errno = 0;
    unsigned long long v = strtoull(buf, &end, 10);
    if (errno || *end) fail("bad limit", arg);
    return (rlim_t)v;
}

static void setLimit(const char *arg) {
    const char *eq = strchr(arg, '='), *colon = eq ? strchr(eq, ':') : NULL;
    if (!eq || !colon) fail("bad -r (NAME=soft:hard)", arg);
    char name[16];
    size_t n = (size_t)(eq - arg);
    if (n >= sizeof name) fail("bad -r name", arg);
    memcpy(name, arg, n); name[n] = 0;
    int res = resource(name);
    if (res < 0) fail("unknown limit", name);
    struct rlimit r;
    if (getrlimit(res, &r)) fail("getrlimit", strerror(errno));
    r.rlim_cur = limitValue(eq + 1, (size_t)(colon - eq - 1), r.rlim_cur, arg);
    r.rlim_max = limitValue(colon + 1, strlen(colon + 1), r.rlim_max, arg);
    // RLIMIT_NOFILE above OPEN_MAX: setrlimit refuses a soft limit over kern.maxfilesperproc.
    if (setrlimit(res, &r)) {
        char detail[128];
        snprintf(detail, sizeof detail, "%s: %s", name, strerror(errno));
        fail("setrlimit", detail);
    }
}

int main(int argc, char **argv) {
    int i = 1;
    for (; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--")) { i++; break; }
        if (i + 1 >= argc && strcmp(a, "-b")) fail("missing value for", a);
        if (!strcmp(a, "-r")) setLimit(argv[++i]);
        else if (!strcmp(a, "-u")) {
            char *end;
            long m = strtol(argv[++i], &end, 8);
            if (*end || m < 0 || m > 0777) fail("bad umask", argv[i]);
            umask((mode_t)m);
        } else if (!strcmp(a, "-n")) {
            char *end;
            long v = strtol(argv[++i], &end, 10);
            if (*end) fail("bad nice", argv[i]);
            if (setpriority(PRIO_PROCESS, 0, (int)v)) fail("setpriority", strerror(errno));
        } else if (!strcmp(a, "-b")) {
            if (setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)) fail("PRIO_DARWIN_BG", strerror(errno));
        } else if (!strcmp(a, "-i")) {
            char *end;
            long p = strtol(argv[++i], &end, 10);
            if (*end) fail("bad iopolicy", argv[i]);
            if (setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, (int)p)) fail("setiopolicy_np", strerror(errno));
        } else if (!strcmp(a, "-S")) {
            char *err = NULL;
            if (sandbox_init(argv[++i], 0, &err)) {
                char detail[512];
                snprintf(detail, sizeof detail, "%s", err ? err : strerror(errno));
                if (err) sandbox_free_error(err);
                fail("sandbox profile", detail);
            }
        } else fail("unknown option", a);
    }
    if (argc - i < 2) fail("usage", "pxr-exec [options] -- path argv0 [args...]");
    const char *path = argv[i];
    argv[i] = NULL;
    execv(path, argv + i + 1);
    fail("exec", strerror(errno));
}
