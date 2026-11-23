// fotobox-cupsd — the on-device CUPS host for iOS (topology L).
//
// A jailbreak LaunchDaemon (unsandboxed, so it CAN spawn + open USB) that runs
// the bundled CUPS runtime, discovers the USB DNP printer, configures its queue,
// and keeps cupsd alive on a fixed loopback port. The sandboxed App-Store app
// connects to that port over IPP and submits print jobs — it never runs any of
// this itself, because iOS forbids a sandboxed app from forking or opening USB.
//
// Reuses the runtime's own C: start_cups_server (fork cupsd), generate_cups_dnp_ppd
// (per-model PPD), add_cups_printer (create the queue). Only the USB discovery
// parse + queue-naming (previously Dart/ObjC on the app side) live here now.
//
// Build: compile with the plugin sources for arm64 iOS, PRINTING_FFI_IOS defined,
// linked against libcups/libcupsimage. Packaged + installed by the .deb.
// NOT built on Linux; compiles on macOS/Xcode (or an arm64-iOS cross toolchain).

#include "../../../src/printing_ffi.h"

#include <cups/cups.h>
#include <ctype.h>
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

// Rootless-Procursus install prefix the .deb lays the runtime under. Overridable
// at build time. Layout mirrors the old CupsRuntime.bundle:
//   <PREFIX>/bin/*.so                      (libcupsd.so, libcupsbe_gutenprint53usb.so, filters)
//   <PREFIX>/share/cups, share/gutenprint/5.3/xml, share/doc/cups
//   <PREFIX>/state                         (writable: config, spool, logs — created at runtime)
#ifndef FOTOBOX_CUPS_PREFIX
#define FOTOBOX_CUPS_PREFIX "/var/jb/usr/lib/fotobox-cups"
#endif
// The fixed loopback port the client connects to (see kDefaultCupsServer in Dart).
#ifndef FOTOBOX_CUPS_PORT
#define FOTOBOX_CUPS_PORT "6310"
#endif
#define DISCOVERY_INTERVAL_SECONDS 5

// Supported Gutenprint DNP / Citizen dye-sub drivers. A raw or wrong-model queue
// is never created.
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

// Spawn the Gutenprint USB backend in discovery mode (no args) and capture its
// stdout+stderr into a caller buffer. Gutenprint derives the URI scheme from
// argv[0]'s basename, so launch it as "gutenprint53+usb". Returns 0 on a clean
// exit(0), -1 otherwise. Mirrors the old in-app ObjC discovery.
static int run_discovery(const char *backend, const char *stp_data_path,
                         char *out, size_t outcap) {
    char tmpl[PATH_MAX];
    snprintf(tmpl, sizeof(tmpl), "%s/state/discovery-XXXXXX", FOTOBOX_CUPS_PREFIX);
    int fd = mkstemp(tmpl);
    if (fd < 0) return -1;
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
    if (rc != 0) { close(fd); return -1; }

    int status = 0;
    if (waitpid(pid, &status, 0) != pid) { close(fd); return -1; }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) { close(fd); return -1; }

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
// serial segment keeps it injective (two physical serials never collide) and a
// valid CUPS queue name. Deterministic so a restart reuses the same queue.
// Returns 0 on success, -1 if it would exceed the 127-char CUPS limit.
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

// Parse the backend's discovery output and create a queue for every supported
// printer found. Each "direct <uri> ..." line names a device; the uri is
// "gutenprint53+usb://<driver>/<serial>".
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
        *slash = '/'; // restore uri for add_cups_printer (device-uri is the full uri)
        if (!driver_supported(driver)) continue;
        if (strchr(serial, '/')) continue; // exactly one path segment

        char queue[160];
        if (queue_name_for(driver, serial, queue, sizeof(queue)) != 0) continue;

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
        fprintf(stderr, "fotobox-cupsd: queue %s ready (%s)\n", queue, uri);
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    setbuf(stderr, NULL);
    // Pin the listen port so the sandboxed client finds us.
    setenv("PRINTING_FFI_CUPSD_PORT", FOTOBOX_CUPS_PORT, 1);

    char root[PATH_MAX], bin[PATH_MAX], data[PATH_MAX], doc[PATH_MAX];
    char backend[PATH_MAX], stp_data_path[PATH_MAX], statedir[PATH_MAX];
    snprintf(root, sizeof(root), "%s/state", FOTOBOX_CUPS_PREFIX);
    snprintf(bin, sizeof(bin), "%s/bin", FOTOBOX_CUPS_PREFIX);
    snprintf(data, sizeof(data), "%s", FOTOBOX_CUPS_PREFIX); // contains share/cups + share/gutenprint
    snprintf(doc, sizeof(doc), "%s/share/doc/cups", FOTOBOX_CUPS_PREFIX);
    snprintf(backend, sizeof(backend), "%s/libcupsbe_gutenprint53usb.so", bin);
    snprintf(stp_data_path, sizeof(stp_data_path),
             "%s/share/gutenprint/5.3/xml", FOTOBOX_CUPS_PREFIX);
    snprintf(statedir, sizeof(statedir), "%s/state", FOTOBOX_CUPS_PREFIX);
    mkdir(statedir, 0755); // best-effort; start_cups_server creates the subtree

    fprintf(stderr, "fotobox-cupsd: starting on 127.0.0.1:%s, prefix %s\n",
            FOTOBOX_CUPS_PORT, FOTOBOX_CUPS_PREFIX);

    for (;;) {
        // start_cups_server is idempotent: it forks cupsd once, then just
        // re-points on later calls while it is alive. This loop also recovers
        // if cupsd dies.
        int port = start_cups_server(root, bin, data, doc);
        if (port <= 0) {
            fprintf(stderr, "fotobox-cupsd: start_cups_server failed: %s\n",
                    get_last_error());
            sleep(DISCOVERY_INTERVAL_SECONDS);
            continue;
        }
        // Rediscover each cycle so attaching/replacing a printer needs no
        // restart; add_cups_printer is a no-op modify for an existing queue.
        char out[65536];
        if (run_discovery(backend, stp_data_path, out, sizeof(out)) == 0) {
            configure_queues(out);
        }
        sleep(DISCOVERY_INTERVAL_SECONDS);
    }
    return 0; // unreached
}
