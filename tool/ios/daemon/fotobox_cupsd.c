// fotobox-cupsd — the on-device CUPS host for iOS (topology L).
//
// A jailbreak LaunchDaemon (unsandboxed, so it CAN spawn + open USB) that runs
// the bundled CUPS runtime, discovers the USB DNP printer, creates its queue,
// and keeps cupsd alive on a fixed loopback port. The sandboxed App-Store app
// connects to that port over IPP and submits print jobs — it never runs any of
// this itself, because iOS forbids a sandboxed app from forking or opening USB.
//
// Runs as `mobile` (UserName in the LaunchDaemon plist), NOT root: the runtime's
// start_cups_server writes "User #<uid>" and relies on cupsd being non-root (no
// setuid privilege drop, no root-ownership checks on filters). That is the same
// uid the runtime was built and tested for when it ran inside the app.
//
// Reuses the runtime's own C: start_cups_server (spawn cupsd),
// generate_cups_dnp_ppd (per-model PPD), add_cups_printer (create the queue).
// Which printers are supported is decided HERE, on the host: the app is a plain
// CUPS client and prints to whatever queue the host marks as default.
//
// Build: tool/ios/daemon/build_daemon_deb.sh (macOS/Xcode). The host test
// (Linux, real cupsd, stub backend) compiles it with -DFOTOBOX_CUPS_PREFIX/
// -DFOTOBOX_CUPS_STATE/-DFOTOBOX_CUPS_PORT pointing at a scratch tree.

#include "../../../src/printing_ffi.h"

#include <cups/cups.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// iOS-only export from printing_ffi.c (not in the ffigen header).
extern int printing_ffi_ios_running(void);

// Read-only install prefix the .deb lays the runtime under (rootless Procursus):
//   <PREFIX>/bin/*.so                (libcupsd.so, filters, Gutenprint backend)
//   <PREFIX>/share/cups, share/gutenprint/5.3/xml, share/doc/cups
#ifndef FOTOBOX_CUPS_PREFIX
#define FOTOBOX_CUPS_PREFIX "/var/jb/usr/lib/fotobox-cups"
#endif
// Writable state (cupsd config, spool, logs, PPDs). Created and chowned to
// mobile by the package's postinst; the install prefix itself is root-owned.
#ifndef FOTOBOX_CUPS_STATE
#define FOTOBOX_CUPS_STATE "/var/jb/var/lib/fotobox-cups"
#endif
// The fixed loopback port the client connects to (kDefaultCupsServer in Dart).
#ifndef FOTOBOX_CUPS_PORT
#define FOTOBOX_CUPS_PORT "6310"
#endif
#define CYCLE_SECONDS 5
// A USB discovery that takes longer than this is wedged; kill it.
#define DISCOVERY_TIMEOUT_SECONDS 20

// Gutenprint dye-sub drivers this host creates queues for (DNP + Citizen). A
// raw or wrong-model queue is never created.
static const char *const kSupportedDrivers[] = {
    "citizen-cw-01", "citizen-cw-02", "citizen-cx-02", "citizen-cx-02w",
    "citizen-cz-01", "dnp-ds40",      "dnp-ds80",      "dnp-ds80dx",
    "dnp-dsrx1",     "dnp-ds620",     "dnp-ds820",     "dnp-qw410",
    NULL,
};

static int driver_supported(const char *driver) {
    for (const char *const *d = kSupportedDrivers; *d; d++)
        if (strcmp(*d, driver) == 0) return 1;
    return 0;
}

// Stop cupsd and everything it spawned with us. launchd sends SIGTERM to the
// job on unload/upgrade; the whole process group goes so a stale cupsd never
// keeps holding the port (or the printer) after the daemon is gone.
static void on_terminate(int sig) {
    signal(sig, SIG_DFL);
    kill(0, sig);
}

// Spawn the Gutenprint USB backend in discovery mode (no args) and capture its
// stdout+stderr. Gutenprint derives the URI scheme from argv[0]'s basename, so
// launch it as "gutenprint53+usb". Returns 0 on a clean exit(0), -1 otherwise.
static int run_discovery(const char *backend, const char *stp_data_path,
                         char *out, size_t outcap) {
    char tmpl[PATH_MAX];
    snprintf(tmpl, sizeof(tmpl), "%s/discovery-XXXXXX", FOTOBOX_CUPS_STATE);
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        fprintf(stderr, "fotobox-cupsd: discovery temp file in %s: %s\n",
                FOTOBOX_CUPS_STATE, strerror(errno));
        return -1;
    }
    unlink(tmpl);
    fcntl(fd, F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO);

    char stp_env[PATH_MAX + 16];
    snprintf(stp_env, sizeof(stp_env), "STP_DATA_PATH=%s", stp_data_path);
    char *const argv[] = {"gutenprint53+usb", NULL};
    char *const env[] = {"PATH=/usr/bin:/bin", "LANG=C", "OLD_URI_SCHEME=0",
                         stp_env, NULL};

    pid_t pid = -1;
    int rc = posix_spawn(&pid, backend, &actions, NULL, argv, env);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        fprintf(stderr, "fotobox-cupsd: spawn %s: %s\n", backend, strerror(rc));
        close(fd);
        return -1;
    }

    int status = 0;
    pid_t done = 0;
    for (int i = 0; i < DISCOVERY_TIMEOUT_SECONDS * 10 && done == 0; i++) {
        done = waitpid(pid, &status, WNOHANG);
        if (done == 0) usleep(100000);
    }
    if (done == 0) {
        fprintf(stderr, "fotobox-cupsd: USB discovery timed out; killed\n");
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        close(fd);
        return -1;
    }
    if (done != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        close(fd);
        return -1;
    }

    ssize_t n = pread(fd, out, outcap - 1, 0);
    close(fd);
    if (n < 0) return -1;
    out[n] = '\0';
    return 0;
}

// Append the hex encoding of one byte.
static void append_hex(char *dst, size_t cap, size_t *len, unsigned char b) {
    static const char hex[] = "0123456789abcdef";
    if (*len + 2 < cap) {
        dst[(*len)++] = hex[b >> 4];
        dst[(*len)++] = hex[b & 0xf];
    }
}

// Build the deterministic queue name "<driver>_<hex(serial)>". Hex-encoding the
// serial keeps it injective (two physical serials never collide) and a valid
// CUPS queue name. Deterministic so a restart reuses the same queue. Returns 0
// on success, -1 if it would exceed the 127-char CUPS limit.
static int queue_name_for(const char *driver, const char *serial,
                          char *out, size_t cap) {
    size_t len = 0;
    int w = snprintf(out, cap, "%s_", driver);
    if (w < 0 || (size_t)w >= cap) return -1;
    len = (size_t)w;
    for (const char *p = serial; *p; p++)
        append_hex(out, cap, &len, (unsigned char)*p);
    if (len + 1 >= cap || len > 127) return -1;
    out[len] = '\0';
    return 0;
}

// True while cupsd is sending a job to a printer. Discovery opens the USB
// devices, so it must never race a backend mid-print. Pending/held jobs do not
// count: a job waiting on a swapped-out printer must not block the replacement
// from getting its queue. A failed query counts as busy (skip one cycle).
static int job_printing(void) {
    cups_job_t *jobs = NULL;
    int n = cupsGetJobs2(CUPS_HTTP_DEFAULT, &jobs, NULL, 0, CUPS_WHICHJOBS_ACTIVE);
    if (n < 0) return 1;
    int printing = 0;
    for (int i = 0; i < n; i++)
        if (jobs[i].state == IPP_JSTATE_PROCESSING) printing = 1;
    cupsFreeJobs(n, jobs);
    return printing;
}

// Make `queue` the server default (what `lpadmin -d` does), so the client —
// which prints to the host's default queue — follows the printer attached most
// recently, e.g. a spare swapped in mid-event.
static void make_default(const char *queue) {
    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL,
                     cupsServer(), ippPort(), "/printers/%s", queue);
    ipp_t *request = ippNewRequest(IPP_OP_CUPS_SET_DEFAULT);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name",
                 NULL, cupsUser());
    ippDelete(cupsDoRequest(CUPS_HTTP_DEFAULT, request, "/admin/"));
    if (cupsLastError() > IPP_STATUS_OK_CONFLICTING)
        fprintf(stderr, "fotobox-cupsd: set default %s failed: %s\n", queue,
                cupsLastErrorString());
}

static int queue_exists(const char *queue) {
    cups_dest_t *dest = cupsGetNamedDest(CUPS_HTTP_DEFAULT, queue, NULL);
    if (!dest) return 0;
    cupsFreeDests(1, dest);
    return 1;
}

// Parse the backend's discovery output and create a queue for every supported
// printer that has none yet. Each "direct <uri> ..." line names a device; the
// uri is "gutenprint53+usb://<driver>/<serial>". An EXISTING queue is never
// touched: CUPS-Add-Modify-Printer restarts the active job and resets the
// printer state, which would loop a print and undo an operator's Pause.
static void configure_queues(const char *discovery) {
    char line[2048];
    const char *p = discovery;
    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t linelen = nl ? (size_t)(nl - p) : strlen(p);
        if (linelen >= sizeof(line)) linelen = sizeof(line) - 1;
        memcpy(line, p, linelen);
        line[linelen] = '\0';
        p = nl ? nl + 1 : p + strlen(p);

        // Expect: direct <uri> "..." ...
        if (strncmp(line, "direct ", 7) != 0) continue;
        char *uri = line + 7;
        while (*uri == ' ') uri++;
        char *sp = strpbrk(uri, " \t");
        if (sp) *sp = '\0';

        const char *scheme = "gutenprint53+usb://";
        if (strncmp(uri, scheme, strlen(scheme)) != 0) continue;
        char *host = uri + strlen(scheme); // "<driver>/<serial>"
        char *slash = strchr(host, '/');
        if (!slash || slash == host || slash[1] == '\0') continue;
        *slash = '\0';
        char driver[64];
        snprintf(driver, sizeof(driver), "%s", host);
        const char *serial = slash + 1;
        *slash = '/'; // restore: the device-uri is the full uri
        if (!driver_supported(driver)) continue;
        if (strchr(serial, '/')) continue; // exactly one path segment

        char queue[160];
        if (queue_name_for(driver, serial, queue, sizeof(queue)) != 0) continue;
        if (queue_exists(queue)) continue;

        const char *ppd = generate_cups_dnp_ppd(driver);
        if (!ppd) {
            fprintf(stderr, "fotobox-cupsd: PPD generation failed for %s: %s\n",
                    driver, get_last_error());
            continue;
        }
        if (!add_cups_printer(queue, uri, ppd)) {
            fprintf(stderr, "fotobox-cupsd: add queue %s failed: %s\n",
                    queue, get_last_error());
            continue;
        }
        make_default(queue);
        fprintf(stderr, "fotobox-cupsd: queue %s ready (%s)\n", queue, uri);
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_terminate);
    signal(SIGINT, on_terminate);
    setbuf(stderr, NULL);
    // Pin the listen port so the sandboxed client finds us.
    setenv("PRINTING_FFI_CUPSD_PORT", FOTOBOX_CUPS_PORT, 1);

    char bin[PATH_MAX], doc[PATH_MAX], backend[PATH_MAX], stp_data_path[PATH_MAX];
    snprintf(bin, sizeof(bin), "%s/bin", FOTOBOX_CUPS_PREFIX);
    snprintf(doc, sizeof(doc), "%s/share/doc/cups", FOTOBOX_CUPS_PREFIX);
    snprintf(backend, sizeof(backend), "%s/libcupsbe_gutenprint53usb.so", bin);
    snprintf(stp_data_path, sizeof(stp_data_path),
             "%s/share/gutenprint/5.3/xml", FOTOBOX_CUPS_PREFIX);

    fprintf(stderr, "fotobox-cupsd: starting as uid %d on 127.0.0.1:%s, prefix %s, state %s\n",
            (int)getuid(), FOTOBOX_CUPS_PORT, FOTOBOX_CUPS_PREFIX, FOTOBOX_CUPS_STATE);
    if (getuid() == 0)
        fprintf(stderr, "fotobox-cupsd: WARNING running as root; the LaunchDaemon "
                        "must set UserName=mobile (cupsd refuses User #0)\n");

    for (;;) {
        // (Re)start cupsd when it is not running; this also recovers a crash.
        if (!printing_ffi_ios_running()) {
            int port = start_cups_server(FOTOBOX_CUPS_STATE, bin, FOTOBOX_CUPS_PREFIX, doc);
            if (port <= 0) {
                fprintf(stderr, "fotobox-cupsd: start_cups_server failed: %s\n",
                        get_last_error());
                sleep(CYCLE_SECONDS);
                continue;
            }
        }
        // Rediscover each cycle so attaching or swapping a printer needs no
        // restart — but never while a job is printing.
        static char out[65536];
        if (!job_printing() &&
            run_discovery(backend, stp_data_path, out, sizeof(out)) == 0) {
            configure_queues(out);
        }
        sleep(CYCLE_SECONDS);
    }
    return 0; // unreached
}
