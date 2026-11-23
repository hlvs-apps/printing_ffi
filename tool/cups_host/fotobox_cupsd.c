// fotobox-cupsd — the CUPS print host the Fotobox app prints to.
//
// The app is only a CUPS client (an App-Store iOS app may not spawn processes
// or open USB). This daemon runs where both are allowed, next to a cupsd, and
// keeps that cupsd's queues in step with the USB dye-sub printers attached:
// it discovers them with the Gutenprint backend, creates one queue per printer,
// defaults the queue's page size to the paper actually loaded, and marks the
// newest queue as the server default (the queue the app prints to).
//
// One program, two hosts:
//
//  (L) iOS, the default build: a jailbreak LaunchDaemon on the same device
//      (tool/ios/daemon/). It starts the bundled CUPS runtime itself
//      (start_cups_server) on 127.0.0.1:6310 and generates PPDs with the
//      bundled genppd. Runs as `mobile`, NOT root: the runtime writes
//      "User #<uid>" and relies on cupsd being non-root (no setuid privilege
//      drop, no root-ownership checks on filters).
//
//  (B) Linux LAN bridge, built with -DFOTOBOX_CUPS_SYSTEM (tool/bridge/): a
//      systemd service next to the distribution's cupsd and Gutenprint, which
//      share the queue on the booth LAN. Runs as root, like any CUPS admin
//      tool, and talks to cupsd over its local socket.
//
// Which printers are supported is decided HERE, on the host: the app prints to
// whatever queue the host marks as default and carries no model list.
//
// The host test (Linux, real cupsd, stub backend) compiles the (L) build with
// -DFOTOBOX_CUPS_PREFIX/-DFOTOBOX_CUPS_STATE/-DFOTOBOX_CUPS_PORT pointing at a
// scratch tree.

#include "../../src/printing_ffi.h"

// This daemon installs driver queues, which in CUPS 2.x still means PPD files:
// the (deprecated-for-clients) PPD API is the right tool here.
#include <cups/cups.h>
#include <cups/ppd.h>
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

#ifdef FOTOBOX_CUPS_SYSTEM
// --- (B) Linux bridge: the distribution's CUPS + Gutenprint -----------------
#ifndef FOTOBOX_CUPS_STATE
#define FOTOBOX_CUPS_STATE "/var/lib/fotobox-print-bridge" // systemd StateDirectory
#endif
#ifndef FOTOBOX_CUPS_BACKEND
#define FOTOBOX_CUPS_BACKEND "/usr/lib/cups/backend/gutenprint53+usb"
#endif
#else
// --- (L) iOS: the bundled runtime -------------------------------------------
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
#define FOTOBOX_CUPS_BACKEND FOTOBOX_CUPS_PREFIX "/bin/libcupsbe_gutenprint53usb.so"
#define FOTOBOX_STP_DATA_PATH FOTOBOX_CUPS_PREFIX "/share/gutenprint/5.3/xml"
#endif

#define CYCLE_SECONDS 5
// A backend run (discovery or media query) that takes longer is wedged; kill it.
#define BACKEND_TIMEOUT_SECONDS 20
// The page size a queue gets when the loaded paper cannot be read or has no
// matching size: 4x6, what every booth prints (the app sends 4x6 or 2x6*2).
#define FALLBACK_PAGE_SIZE "w288h432"

// Gutenprint dye-sub drivers this host creates queues for (DNP + Citizen). A
// raw or wrong-model queue is never created.
static const char *const kSupportedDrivers[] = {
    "citizen-cw-01", "citizen-cw-02", "citizen-cx-02", "citizen-cx-02w",
    "citizen-cz-01", "dnp-ds40",      "dnp-ds80",      "dnp-ds80dx",
    "dnp-dsrx1",     "dnp-ds620",     "dnp-ds820",     "dnp-qw410",
    NULL,
};

// The paper a DNP/Citizen reports as loaded (Gutenprint's dnpds40 backend,
// dnpds40_media_types: "6x4 (PC)", "6x8 (A5) Sticker", ...) -> the Gutenprint
// page size for printing that paper whole.
static const struct {
    const char *media;
    const char *page_size;
} kMediaPageSizes[] = {
    {"6x4", "w288h432"},   {"4x6", "w288h432"},   {"5x3.5", "B7"},
    {"5x7", "w360h504"},   {"6x8", "w432h576"},   {"6x9", "w432h648"},
    {"8x10", "c8x10"},     {"8x12", "w576h864"},
};

static int driver_supported(const char *driver) {
    for (const char *const *d = kSupportedDrivers; *d; d++)
        if (strcmp(*d, driver) == 0) return 1;
    return 0;
}

// Stop everything spawned with us. launchd / systemd send SIGTERM on unload,
// upgrade or stop; on iOS the whole process group goes so a stale cupsd never
// keeps holding the port (or the printer) after the daemon is gone.
static void on_terminate(int sig) {
    signal(sig, SIG_DFL);
    kill(0, sig);
}

// Run the Gutenprint USB backend with `extra_env` added and capture its
// stdout+stderr into `out`. Gutenprint derives the URI scheme from argv[0]'s
// basename, so it runs as "gutenprint53+usb". With no arguments and no
// DEVICE_URI it lists devices (discovery); BACKEND_STATS_ONLY makes it report
// one printer's state instead. Returns 0 on a clean exit(0), -1 otherwise.
static int run_backend(const char *const extra_env[], char *out, size_t outcap) {
    char tmpl[PATH_MAX];
    snprintf(tmpl, sizeof(tmpl), "%s/backend-XXXXXX", FOTOBOX_CUPS_STATE);
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        fprintf(stderr, "fotobox-cupsd: backend output file in %s: %s\n",
                FOTOBOX_CUPS_STATE, strerror(errno));
        return -1;
    }
    unlink(tmpl);
    fcntl(fd, F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO);

    char *env[16];
    size_t n = 0;
    env[n++] = "PATH=/usr/bin:/bin";
    env[n++] = "LANG=C";
    env[n++] = "OLD_URI_SCHEME=0";
#ifdef FOTOBOX_STP_DATA_PATH
    env[n++] = "STP_DATA_PATH=" FOTOBOX_STP_DATA_PATH;
#endif
    for (const char *const *e = extra_env; e && *e && n + 1 < sizeof(env) / sizeof(*env); e++)
        env[n++] = (char *)*e;
    env[n] = NULL;
    char *const argv[] = {"gutenprint53+usb", NULL};

    pid_t pid = -1;
    int rc = posix_spawn(&pid, FOTOBOX_CUPS_BACKEND, &actions, NULL, argv, env);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        fprintf(stderr, "fotobox-cupsd: spawn %s: %s\n", FOTOBOX_CUPS_BACKEND, strerror(rc));
        close(fd);
        return -1;
    }

    int status = 0;
    pid_t done = 0;
    for (int i = 0; i < BACKEND_TIMEOUT_SECONDS * 10 && done == 0; i++) {
        done = waitpid(pid, &status, WNOHANG);
        if (done == 0) usleep(100000);
    }
    if (done == 0) {
        fprintf(stderr, "fotobox-cupsd: USB backend timed out; killed\n");
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        close(fd);
        return -1;
    }
    if (done != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        close(fd);
        return -1;
    }

    ssize_t got = pread(fd, out, outcap - 1, 0);
    close(fd);
    if (got < 0) return -1;
    out[got] = '\0';
    return 0;
}

// The page size for the paper loaded in printer `serial` (driver `driver`),
// or NULL when the printer cannot be asked or reports paper we have no size
// for. Asks the backend for the printer's stats (BACKEND_STATS_ONLY=2 prints
// them as JSON, `"mediatype": "6x4 (PC)"`), the same query `-s` runs by hand.
static const char *loaded_page_size(const char *driver, const char *serial) {
    char backend_env[96], serial_env[160];
    snprintf(backend_env, sizeof(backend_env), "BACKEND=%s", driver);
    snprintf(serial_env, sizeof(serial_env), "SERIAL=%s", serial);
    const char *const env[] = {backend_env, serial_env, "BACKEND_STATS_ONLY=2", NULL};
    static char out[16384];
    if (run_backend(env, out, sizeof(out)) != 0) {
        fprintf(stderr, "fotobox-cupsd: could not read the paper loaded in %s/%s\n",
                driver, serial);
        return NULL;
    }
    const char *key = strstr(out, "\"mediatype\": \"");
    if (!key) return NULL;
    const char *media = key + strlen("\"mediatype\": \"");
    for (size_t i = 0; i < sizeof(kMediaPageSizes) / sizeof(*kMediaPageSizes); i++) {
        size_t len = strlen(kMediaPageSizes[i].media);
        if (strncmp(media, kMediaPageSizes[i].media, len) == 0 &&
            (media[len] == ' ' || media[len] == '"')) {
            fprintf(stderr, "fotobox-cupsd: %s/%s has %.*s loaded\n", driver, serial,
                    (int)strcspn(media, "\""), media);
            return kMediaPageSizes[i].page_size;
        }
    }
    fprintf(stderr, "fotobox-cupsd: %s/%s reports unknown paper %.*s\n", driver, serial,
            (int)strcspn(media, "\""), media);
    return NULL;
}

// Copy PPD `src` to `dst` with `size` as its default page size: what
// `lpadmin -o PageSize=<size>` does to a queue's PPD (systemv/lpadmin.c). The
// size-keyed defaults (PageSize, PageRegion, PaperDimension, ImageableArea) all
// name the same choice. Returns -1, writing nothing, when the PPD has no such
// size.
static int write_default_page_size(const char *src, const char *size, const char *dst) {
    ppd_file_t *ppd = ppdOpenFile(src);
    if (!ppd) return -1;
    ppd_option_t *page_size = ppdFindOption(ppd, "PageSize");
    int known = page_size && ppdFindChoice(page_size, size);
    ppdClose(ppd);
    if (!known) return -1;

    cups_file_t *in = cupsFileOpen(src, "r");
    if (!in) return -1;
    cups_file_t *out = cupsFileOpen(dst, "w");
    if (!out) {
        cupsFileClose(in);
        return -1;
    }
    static const char *const kSizeKeywords[] = {"PageSize", "PageRegion",
                                                "PaperDimension", "ImageableArea"};
    char line[4096];
    while (cupsFileGets(in, line, sizeof(line))) {
        int replaced = 0;
        for (size_t i = 0; i < sizeof(kSizeKeywords) / sizeof(*kSizeKeywords); i++) {
            char prefix[64];
            snprintf(prefix, sizeof(prefix), "*Default%s:", kSizeKeywords[i]);
            if (strncmp(line, prefix, strlen(prefix)) == 0) {
                cupsFilePrintf(out, "%s %s\n", prefix, size);
                replaced = 1;
                break;
            }
        }
        if (!replaced) cupsFilePrintf(out, "%s\n", line);
    }
    cupsFileClose(in);
    return cupsFileClose(out) == 0 ? 0 : -1;
}

// Write `src` to `dst` defaulting to the page size of the paper loaded in the
// printer, else 4x6. Returns the PPD to install: `dst`, or `src` unchanged if
// the PPD offers neither size (Gutenprint's own default then stands).
static const char *ppd_for_loaded_paper(const char *src, const char *driver,
                                        const char *serial, const char *dst) {
    const char *size = loaded_page_size(driver, serial);
    if (size && write_default_page_size(src, size, dst) == 0) return dst;
    if (write_default_page_size(src, FALLBACK_PAGE_SIZE, dst) == 0) {
        if (size)
            fprintf(stderr, "fotobox-cupsd: %s has no page size %s; defaulting to %s\n",
                    driver, size, FALLBACK_PAGE_SIZE);
        return dst;
    }
    fprintf(stderr, "fotobox-cupsd: %s PPD has no %s page size; keeping its default\n",
            driver, FALLBACK_PAGE_SIZE);
    return src;
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

// True while cupsd is sending a job to a printer. The backend opens the USB
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

// Send one CUPS admin request for `queue` (built by the caller), optionally
// with a PPD file as its body. Returns 0 on success.
static int admin_request(ipp_t *request, const char *queue, const char *ppd,
                         const char *what) {
    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL,
                     cupsServer(), ippPort(), "/printers/%s", queue);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name",
                 NULL, cupsUser());
    ippDelete(ppd ? cupsDoFileRequest(CUPS_HTTP_DEFAULT, request, "/admin/", ppd)
                  : cupsDoRequest(CUPS_HTTP_DEFAULT, request, "/admin/"));
    if (cupsLastError() > IPP_STATUS_OK_CONFLICTING) {
        fprintf(stderr, "fotobox-cupsd: %s %s failed: %s\n", what, queue,
                cupsLastErrorString());
        return -1;
    }
    return 0;
}

// Make `queue` the server default (what `lpadmin -d` does), so the client —
// which prints to the host's default queue — follows the printer attached most
// recently, e.g. a spare swapped in mid-event.
static void make_default(const char *queue) {
    admin_request(ippNewRequest(IPP_OP_CUPS_SET_DEFAULT), queue, NULL, "set default");
}

// Replace only the PPD of an existing queue (what `lpadmin -p <queue> -P <ppd>`
// does). Unlike add_cups_printer it sends no printer-state or accepting flag, so
// an operator's Pause or Reject survives.
static int replace_ppd(const char *queue, const char *ppd) {
    return admin_request(ippNewRequest(IPP_OP_CUPS_ADD_MODIFY_PRINTER), queue, ppd,
                         "update PPD of");
}

static int queue_exists(const char *queue) {
    cups_dest_t *dest = cupsGetNamedDest(CUPS_HTTP_DEFAULT, queue, NULL);
    if (!dest) return 0;
    cupsFreeDests(1, dest);
    return 1;
}

// A queue's page size is set from the loaded paper ONCE: when this daemon
// creates the queue, or the first time it meets a queue an older daemon created
// with Gutenprint's default (3.5x5 for DNP). Afterwards the operator owns the
// queue's defaults; this marker records that the size was set.
static void page_size_marker(const char *queue, char *path, size_t cap) {
    snprintf(path, cap, "%s/page-size-set/%s", FOTOBOX_CUPS_STATE, queue);
}

static int page_size_set(const char *queue) {
    char path[PATH_MAX];
    page_size_marker(queue, path, sizeof(path));
    return access(path, F_OK) == 0;
}

static void mark_page_size_set(const char *queue) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/page-size-set", FOTOBOX_CUPS_STATE);
    mkdir(path, 0755);
    page_size_marker(queue, path, sizeof(path));
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) close(fd);
}

// The driver's PPD, as a file to read. Returns the path, or NULL; *temp is
// set when the caller must unlink it.
static const char *driver_ppd(const char *driver, int *temp) {
    *temp = 0;
#ifdef FOTOBOX_CUPS_SYSTEM
    // Ask cupsd for the distribution's Gutenprint PPD (what `lpadmin -m` would
    // install), the same expert PPD the bundled genppd writes on iOS.
    char model[128];
    snprintf(model, sizeof(model), "gutenprint.5.3://%s/expert", driver);
    const char *ppd = cupsGetServerPPD(CUPS_HTTP_DEFAULT, model);
    if (!ppd) {
        fprintf(stderr, "fotobox-cupsd: no PPD for %s: %s\n", model, cupsLastErrorString());
        return NULL;
    }
    *temp = 1;
    return ppd;
#else
    const char *ppd = generate_cups_dnp_ppd(driver);
    if (!ppd)
        fprintf(stderr, "fotobox-cupsd: PPD generation failed for %s: %s\n", driver,
                get_last_error());
    return ppd;
#endif
}

// A new printer: create its queue with the loaded paper as default page size,
// and make it the default queue.
static void create_queue(const char *queue, const char *uri, const char *driver,
                         const char *serial) {
    int temp = 0;
    const char *src = driver_ppd(driver, &temp);
    if (!src) return;
    char dst[PATH_MAX];
    snprintf(dst, sizeof(dst), "%s/%s.ppd", FOTOBOX_CUPS_STATE, queue);
    const char *ppd = ppd_for_loaded_paper(src, driver, serial, dst);
    if (add_cups_printer(queue, uri, ppd)) {
        mark_page_size_set(queue);
        make_default(queue);
        fprintf(stderr, "fotobox-cupsd: queue %s ready (%s)\n", queue, uri);
    } else {
        fprintf(stderr, "fotobox-cupsd: add queue %s failed: %s\n", queue, get_last_error());
    }
    unlink(dst);
    if (temp) unlink(src);
}

// A queue an older daemon created with Gutenprint's default page size: set the
// loaded paper's size on its PPD, once, keeping every other setting.
static void set_page_size_once(const char *queue, const char *driver, const char *serial) {
    char src[PATH_MAX] = "";
    time_t modtime = 0;
    if (cupsGetPPD3(CUPS_HTTP_DEFAULT, queue, &modtime, src, sizeof(src)) != HTTP_STATUS_OK) {
        fprintf(stderr, "fotobox-cupsd: read PPD of %s: %s\n", queue, cupsLastErrorString());
        if (src[0]) unlink(src);
        return;
    }
    char dst[PATH_MAX];
    snprintf(dst, sizeof(dst), "%s/%s.ppd", FOTOBOX_CUPS_STATE, queue);
    const char *ppd = ppd_for_loaded_paper(src, driver, serial, dst);
    if (ppd == src || replace_ppd(queue, ppd) == 0) {
        mark_page_size_set(queue);
        if (ppd != src) fprintf(stderr, "fotobox-cupsd: queue %s page size set\n", queue);
    }
    unlink(dst);
    unlink(src);
}

// Parse the backend's discovery output and give every supported printer a
// queue. Each "direct <uri> ..." line names a device; the uri is
// "gutenprint53+usb://<driver>/<serial>". An existing queue is never recreated:
// CUPS-Add-Modify-Printer restarts the active job and resets the printer state,
// which would loop a print and undo an operator's Pause.
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
        char serial[128];
        snprintf(serial, sizeof(serial), "%s", slash + 1);
        *slash = '/'; // restore: the device-uri is the full uri
        if (!driver_supported(driver)) continue;
        if (strchr(serial, '/')) continue; // exactly one path segment

        char queue[160];
        if (queue_name_for(driver, serial, queue, sizeof(queue)) != 0) continue;
        if (!queue_exists(queue))
            create_queue(queue, uri, driver, serial);
        else if (!page_size_set(queue))
            set_page_size_once(queue, driver, serial);
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_terminate);
    signal(SIGINT, on_terminate);
    setbuf(stderr, NULL);
    // libcups writes fetched PPDs to TMPDIR; keep them in our own state.
    setenv("TMPDIR", FOTOBOX_CUPS_STATE, 1);

#ifdef FOTOBOX_CUPS_SYSTEM
    fprintf(stderr, "fotobox-cupsd: bridge mode, cupsd %s, state %s\n", cupsServer(),
            FOTOBOX_CUPS_STATE);
#else
    // Pin the listen port so the sandboxed client finds us.
    setenv("PRINTING_FFI_CUPSD_PORT", FOTOBOX_CUPS_PORT, 1);
    char bin[PATH_MAX], doc[PATH_MAX];
    snprintf(bin, sizeof(bin), "%s/bin", FOTOBOX_CUPS_PREFIX);
    snprintf(doc, sizeof(doc), "%s/share/doc/cups", FOTOBOX_CUPS_PREFIX);

    fprintf(stderr, "fotobox-cupsd: starting as uid %d on 127.0.0.1:%s, prefix %s, state %s\n",
            (int)getuid(), FOTOBOX_CUPS_PORT, FOTOBOX_CUPS_PREFIX, FOTOBOX_CUPS_STATE);
    if (getuid() == 0)
        fprintf(stderr, "fotobox-cupsd: WARNING running as root; the LaunchDaemon "
                        "must set UserName=mobile (cupsd refuses User #0)\n");
#endif

    for (;;) {
#ifndef FOTOBOX_CUPS_SYSTEM
        // (Re)start cupsd when it is not running; this also recovers a crash.
        // On the bridge, systemd owns cupsd.
        if (!printing_ffi_ios_running()) {
            int port = start_cups_server(FOTOBOX_CUPS_STATE, bin, FOTOBOX_CUPS_PREFIX, doc);
            if (port <= 0) {
                fprintf(stderr, "fotobox-cupsd: start_cups_server failed: %s\n",
                        get_last_error());
                sleep(CYCLE_SECONDS);
                continue;
            }
        }
#endif
        // Rediscover each cycle so attaching or swapping a printer needs no
        // restart — but never while a job is printing.
        static char out[65536];
        if (!job_printing() && run_backend(NULL, out, sizeof(out)) == 0)
            configure_queues(out);
        sleep(CYCLE_SECONDS);
    }
    return 0; // unreached
}
