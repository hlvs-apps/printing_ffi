# CUPS 2.4.x cross-compile for Android arm64 — build notes

Feasibility spike: cross-compile CUPS 2.4.x (client lib + scheduler + backends)
for Android arm64 with the NDK. **STATUS: SUCCESS** — full build, all required
symbols exported, all outputs verified AArch64.

## Target
- CUPS **2.4.19** (latest v2.4.* tag as of 2026-07-01; constraint asked for newest 2.4.x)
- Source tarball (ships a ready `./configure`, no autogen needed):
  https://github.com/OpenPrinting/cups/releases/download/v2.4.19/cups-2.4.19-source.tar.gz
- ABI: **aarch64-linux-android**, **API 24**
- NDK: `/Users/henrisauer/Library/Android/sdk/ndk/27.0.12077973`
- Toolchain: `$NDK/toolchains/llvm/prebuilt/darwin-x86_64` (clang 18.0.1)

## How to build
```
tool/android/build-cups.sh          # incremental (idempotent)
tool/android/build-cups.sh clean    # wipe build/ + out/ and start fresh
```
The script: sets a clean cross env, downloads+caches the tarball, extracts,
applies patches (stamped, idempotent), configures (only if not yet configured),
`make -j`, then runs `stage.sh` to populate `out/arm64/`.

## Files
- `build-cups.sh` — env + download + configure + build + stage. Re-runnable.
- `stage.sh` — copies built artifacts into `out/arm64/` in on-device layout.
- `android-compat.h` — force-included (`-include`) shim for bionic gaps (below).
- `patches/` — two minimal source patches, applied with `patch -p1`.
- `build/` — extraction + build tree (gitignored).
- `cache/` — downloaded tarball (gitignored).
- `logs/` — build logs (build-clean.log, stage.log, etc.).
- `out/arm64/` — staged deliverables (committed).

## Final configure flags
```
--host=aarch64-linux-android
--prefix=/system/cups
--with-tls=no            # no gnutls/openssl cross build for the spike
--with-dnssd=no          # no avahi/mdns on Android
--with-ondemand=no       # no launchd/systemd/upstart
--disable-dbus
--disable-pam
--disable-libusb         # AC_ARG_ENABLE accepts it; suppresses HOST libusb taint
--without-rcdir          # no SysV rc scripts
--with-components=all    # libcups (FULL 2.x API, incl. PPD) + cupsd + backends + filters
--with-cups-user=shell
--with-cups-group=shell
--with-domainsocket=/data/local/tmp/cups.sock
```
IMPORTANT: CUPS 2.4.x configure has NO separate `--disable-gssapi` /
`--disable-avahi` / `--disable-systemd` / `--disable-launchd` / `--disable-acl`
flags (those are the suggested ones that DON'T exist here). GSSAPI/libusb/ACL are
OFF by default; TLS/DNSSD/on-demand use the `--with-*=no` forms above.
`--with-components=all` (not `libcupslite`) is what gives us the full classic 2.x
API including `cupsGetPPD`/`ppdOpenFile`.

## Host environment pollution (the #1 gotcha — read this)
The host `~/.zshrc` exports, into every shell:
- `LDFLAGS=-L/usr/local/opt/ruby/lib`
- `CPPFLAGS=-I/usr/local/opt/ruby/include`
- `PKG_CONFIG_PATH=:/usr/local/opt/qt@5/lib/pkgconfig`
and Homebrew has an **x86_64** `libusb-1.0` installed.

The first naive configure leaked ALL of these into Makedefs: ruby `-L` in
LDFLAGS, host x86_64 libusb `-I`/`-L` in CFLAGS/LIBUSB. That would silently link
host objects into an "arm64" build. `build-cups.sh` therefore:
- OVERRIDES (not appends) `CFLAGS/CPPFLAGS/LDFLAGS/LIBS` to clean values,
- sets `PKG_CONFIG_PATH=""` and `PKG_CONFIG_LIBDIR=<empty dir>` so pkg-config
  cannot discover any host library,
- passes `--disable-libusb`.
After this, `readelf -d` shows ONLY bionic libs as NEEDED (no Cellar/usr/local).

## Patches (minimal, scoped to __ANDROID__)
1. **0001-android-no-nl_langinfo-api24.patch** (cups/language.c)
   - bionic's `nl_langinfo()` is `__INTRODUCED_IN(26)`; at API 24 the function is
     hidden but the `CODESET` macro is still defined, so CUPS's `#ifdef CODESET`
     guard is true and the call fails to compile (implicit declaration).
   - Fix: `#undef CODESET` on Android API < 26 right after `<langinfo.h>`. CUPS
     already falls back to UTF-8 when no charset is detected — correct for Android.

2. **0002-android-no-pthread_cancel.patch** (cups/thread.c)
   - bionic has no `pthread_cancel()`. `_cupsThreadCancel()` wraps it but has NO
     callers anywhere in the tree (verified by grep), so on Android it's a no-op.

## Compat shim: android-compat.h (force-included via `-include`)
bionic gates these libc account-DB functions at API >= 26 and ships NO crypt():
`endpwent/setpwent/getpwent`, `endgrent/setgrent/getgrent`, `crypt`.
cupsd's scheduler calls `endpwent`/`endgrent` (cleanup) and `crypt` (Basic-auth
password compare only). On Android there is no /etc/passwd or /etc/shadow and we
do not use Basic auth (cupsd runs locally over a unix socket), so the shim
provides `static inline` no-op stubs (crypt returns NULL => Basic-auth compare
always fails, the safe default). `static inline` means no Makefile edits and no
link-time symbols. Activated only on `__ANDROID__` and (for pwent/grent) API < 26.
Verified: `nm -uD cupsd` shows NO undefined crypt/pwent/grent/langinfo/
pthread_cancel symbols.

## Verification results

### file(1)
```
libcups.so.2 : ELF 64-bit LSB shared object, ARM aarch64, dynamically linked
cupsd        : ELF 64-bit LSB pie executable, ARM aarch64, interpreter /system/bin/linker64
backend/socket,ipp,lpd : ELF 64-bit LSB pie executable, ARM aarch64
```

### llvm-readelf -h
```
libcups.so.2 : Class ELF64, Type DYN, Machine AArch64
cupsd        : Class ELF64, Type DYN (PIE), Machine AArch64
```

### llvm-nm -D libcups.so.2 — ALL required symbols present (T = exported):
```
cupsGetDests  cupsGetDest  cupsPrintFile  cupsDoRequest  httpConnectEncrypt
cupsGetPPD    ppdOpenFile  cupsGetJobs    cupsLastErrorString  cupsServer  ippPort
```
(581 exported `T` symbols total; full classic 2.x API incl. cupsGetPPD2/3,
cupsAddDest, cupsCreateJob, ippNew, httpConnect2, …)

### llvm-readelf -d (dynamic deps) — NO host taint:
```
libcups.so.2 NEEDED: libz.so libm.so libdl.so libc.so ; SONAME libcups.so.2 ; RUNPATH /system/cups/lib
cupsd        NEEDED: libm.so libz.so libcups.so.2 libdl.so libc.so
backend/socket NEEDED: libcups.so.2 libdl.so libc.so
```
RUNPATH is `/system/cups/lib` (the prefix); override at runtime with
`LD_LIBRARY_PATH` if the on-device layout differs.

## Staged tree (tool/android/out/arm64/, ~5.5 MB)
```
bin/        cancel cupsaccept cupsdisable cupsenable cupsreject
            lp lpadmin lpc lpoptions lpq lpr lprm lpstat
etc/cups/   cupsd.conf.default
lib/        libcups.so -> libcups.so.2      (2.2 MB, the client library)
            libcups.so.2
            libcupsimage.so -> libcupsimage.so.2
            libcupsimage.so.2
lib/cups/backend/   socket  ipp  lpd  http(->ipp)  snmp  usb
lib/cups/daemon/    cups-deviced cups-driverd cups-exec cups-lpd cupsfilter
sbin/       cupsd                            (1.4 MB, the scheduler)
share/cups/mime/    mime.types  mime.convs   (needed to boot)
share/cups/data/    font.defs media.defs raster.defs + ppdc headers etc.
```
Note: outputs are NOT stripped (keep debug_info for the spike). Strip later with
`llvm-strip` for size if shipping.

## What's built vs disabled/stubbed
- BUILT: libcups.so (full API), cupsd, backends socket/ipp/lpd (+http/snmp/usb),
  helpers cups-deviced/cups-driverd/cups-exec/cups-lpd/cupsfilter, all client
  tools (lp/lpr/lpstat/lpadmin/...), libcupsimage.
- DISABLED (by design / Android-incompatible): TLS (so no `https` backend),
  DNS-SD (no `dnssd` backend), dbus, PAM, GSSAPI, on-demand launch, libusb.
- STUBBED (android-compat.h): crypt (returns NULL), endpwent/endgrent/setpwent/
  setgrent/getpwent/getgrent (no-ops). Only the scheduler's Basic-auth + account
  cleanup paths touch these; not used at runtime.

## Known / deferred (NOT blockers for the spike, handle at runtime/next step)
- `usb` backend was built in its NO-libusb variant (enumerates nothing). Harmless;
  USB is handled elsewhere per project design.
- TLS is off — IPP-over-TLS (ipps) and the https backend are unavailable. Plain
  `ipp://` / `socket://` work. Add a cross-built gnutls/openssl later if needed.
- crypt() stub means cupsd Basic auth always denies. Fine (local socket, no auth).
- cupsd boot on-device (uid/gid `shell`, socket path, cups-files.conf, spool dirs)
  is a SEPARATE step — not attempted here (no adb testing per instructions).
- GNU Make on host is 3.81 (old) but builds fine.

## Status log
- [done] dirs, tarball download+extract, scripts
- [done] fixed host env taint (LDFLAGS/CPPFLAGS/PKG_CONFIG + libusb)
- [done] patch 0001 nl_langinfo, patch 0002 pthread_cancel
- [done] android-compat.h shim (crypt + pwent/grent)
- [done] FULL CLEAN BUILD SUCCEEDS (exit 0, 0 compile errors)
- [done] staged outputs; verified AArch64 (file + readelf) and symbol exports (nm)
- [done] verified no host-lib taint in NEEDED; idempotent re-run confirmed
- **DONE — build is reproducible and verified.**

## On-device boot test (spike 2)

**RESULT: PASS.** The cross-built `cupsd` boots on a real device, binds a
localhost TCP port, and answers IPP. Bonus also PASS: `lpadmin` creates a queue.

### Device
- Samsung Galaxy S25 (SM-S931B), Android **API 36**, **arm64-v8a**, NON-rooted.
- Run entirely as the `shell` user (uid/gid 2000) from `/data/local/tmp` (where
  shell is allowed to exec). Device pinned with `adb -s RFCY90BL8GH`.
- `shell` user has group `inet` (3003) -> can bind sockets.

### Getting the tree onto the device (gotcha)
`adb push tool/android/out/arm64 ...` FAILS: the device fs rejects symlink
creation (`remote symlink failed: Permission denied`) and the staged tree has 6
symlinks. Workaround that works:
```
cd tool/android/out/arm64 && tar -czf /tmp/cupstest.tgz .
adb -s RFCY90BL8GH push /tmp/cupstest.tgz /data/local/tmp/cupstest.tgz
adb -s RFCY90BL8GH shell "mkdir -p /data/local/tmp/cupstest && cd /data/local/tmp/cupstest && tar -xzf /data/local/tmp/cupstest.tgz"
adb -s RFCY90BL8GH shell "find /data/local/tmp/cupstest -name '._*' -delete"   # strip macOS AppleDouble junk
adb -s RFCY90BL8GH shell "chmod -R 755 /data/local/tmp/cupstest"
```
Device toybox `tar`/`ln` preserve the symlinks; verified all 6 resolve on-device.

### Runtime dirs created on device
```
adb -s RFCY90BL8GH shell "mkdir -p /data/local/tmp/cupstest/var/spool/tmp \
  /data/local/tmp/cupstest/var/run /data/local/tmp/cupstest/var/log \
  /data/local/tmp/cupstest/var/cache /data/local/tmp/cupstest/etc/cups/ppd"
```

### Configs used (committed at tool/android/device-test/)
Both files were pushed to `/data/local/tmp/cupstest/etc/cups/`.

`cups-files.conf` (paths + identity):
```
User shell
Group shell
ServerRoot   /data/local/tmp/cupstest/etc/cups
ServerBin    /data/local/tmp/cupstest/lib/cups
DataDir      /data/local/tmp/cupstest/share/cups
RequestRoot  /data/local/tmp/cupstest/var/spool
StateDir     /data/local/tmp/cupstest/var/run
CacheDir     /data/local/tmp/cupstest/var/cache
TempDir      /data/local/tmp/cupstest/var/spool/tmp
AccessLog    /data/local/tmp/cupstest/var/log/access_log
ErrorLog     /data/local/tmp/cupstest/var/log/error_log
PageLog      /data/local/tmp/cupstest/var/log/page_log
SystemGroup  shell
```
Note: `User shell` worked by NAME — bionic getpwnam resolved "shell"->2000. No
numeric fallback was needed.

`cupsd.conf` (minimal, TCP-only, no TLS, no auth):
```
LogLevel debug2
MaxLogSize 0
Listen 127.0.0.1:10631
Browsing Off
DefaultAuthType None
WebInterface No
ErrorPolicy retry-job
<Location />            Order allow,deny / Allow from all   </Location>
<Location /admin>       Order allow,deny / Allow from all   </Location>
<Location /admin/conf>  Order allow,deny / Allow from all   </Location>
<Policy default>
  JobPrivateAccess all  JobPrivateValues none
  SubscriptionPrivateAccess all  SubscriptionPrivateValues none
  <Limit All> Order allow,deny / Allow from all </Limit>
</Policy>
```

### Config validation (passed first try)
```
$ cupsd -t -c .../cupsd.conf -s .../cups-files.conf
Filter "pstops" not found.        # expected: we staged backends, not filters
Filter "rastertopwg" not found.   # expected
".../cups-files.conf" is OK.
".../cupsd.conf" is OK.           # exit 0
```

### Boot command
```
adb -s RFCY90BL8GH shell "cd /data/local/tmp/cupstest && \
  LD_LIBRARY_PATH=/data/local/tmp/cupstest/lib nohup ./sbin/cupsd -f \
    -c /data/local/tmp/cupstest/etc/cups/cupsd.conf \
    -s /data/local/tmp/cupstest/etc/cups/cups-files.conf \
  >/data/local/tmp/cupstest/var/log/cupsd.stdout 2>&1 &"
```
cupsd ran as non-root with NO privilege-drop error (User/Group == current uid, so
no setuid attempted). error_log boot banner:
```
Listening to 127.0.0.1:10631 (IPv4)
Loaded MIME database from ".../share/cups/mime" and ".../etc/cups": 36 types, 1 filters...
Full reload complete.
Listening to 127.0.0.1:10631 on fd 4...
cupsdAddEvent(... "Scheduler started in foreground.")
```
Process confirmed alive (`ps`: cupsd in do_epoll_wait), `ss -ltn` shows
`LISTEN 127.0.0.1:10631`, and `/proc/<pid>/maps` shows our
`/data/local/tmp/cupstest/lib/libcups.so.2` mapped. The MIME database loaded
with NO errors — no need to duplicate mime files into ServerRoot.

### VERIFY — the success bar
```
$ LD_LIBRARY_PATH=.../lib CUPS_SERVER=127.0.0.1:10631 bin/lpstat -r
scheduler is running              # exit 0  <-- PASS

$ ... bin/lpstat -t
... "No destinations added." (x4, expected: 0 queues)
scheduler is running
no system default destination     # exit 1 only b/c no default dest
```

### BONUS — queue creation (CUPS-Add-Modify-Printer)
```
$ ... bin/lpadmin -h 127.0.0.1:10631 -p test -E -v socket://192.0.2.1:9100 -m raw
lpadmin: Raw queues are deprecated...      # exit 0, warning only

$ ... bin/lpstat -v
device for test: socket://192.0.2.1:9100

$ ... bin/lpstat -p
printer test is idle.  enabled since Wed Jul  1 01:11:01 2026
```
Server side (error_log): `CUPS-Add-Modify-Printer` -> `Setting test device-uri to
"socket://192.0.2.1:9100"` -> `Returning IPP successful-ok`. access_log:
`POST /admin/ HTTP/1.1 200 ... CUPS-Add-Modify-Printer successful-ok`.

### Errors hit + fixes
- adb symlink push failure -> tar workaround (above). Only real blocker; solved.
- macOS `._*` files in the tarball -> deleted on-device (cosmetic).
- No other errors. cupsd booted clean; configs valid first try; `shell` user
  resolved by name; MIME loaded; no root requirement.

### Deferred (NOT spike failures)
- Actual JOB EXECUTION via cups-exec + backend is untested — separate follow-up.
  Non-raw print paths will also need the filters (pstops/rastertopwg) we didn't
  build. Boot + IPP + queue creation are proven; job spool->print is next.
- TLS off at build time -> no ipps/https. Expected.

### Cleanup
cupsd killed (`pkill -f cupsd`). The `/data/local/tmp/cupstest` tree + logs left
in place for inspection. Nothing outside /data/local/tmp touched; no reboot.

## On-device job-execution test (spike 2b)

**RESULT: PASS.** A job's bytes travel the full path spool -> scheduler ->
fork/execv -> backend -> device output, on a NON-rooted Samsung S25 (API 36,
SELinux **Enforcing**, domain `u:r:shell:s0`). Out-file contained the exact test
string. **The reviewer-flagged `cups-exec` risk is a NON-issue: cups-exec is
never invoked on this build** (it is compiled-out dead code — see "How the
backend is actually launched" below). No SELinux denials.

### Important correction: CUPS 2.4.x has NO `file` backend
The plan called for the `file://` backend, but CUPS 2.4.19 source ships only
`ipp, lpd, usb, snmp, socket` (+`dnssd`). `file.c` does not exist in the 2.4.x
tree (the `file` pseudo-backend was a CUPS 1.x feature, since removed). So
`FileDevice Yes` in cups-files.conf has nothing to drive. We proved the same
thing — bytes reaching a backend's device output — with the **socket backend**
pointed at a local `toybox nc` listener that writes the stream to a file. This
exercises the identical scheduler -> fork -> backend -> write path.

### Setup (deltas from spike 2)
- Added `FileDevice Yes` to `tool/android/device-test/cups-files.conf` (kept for
  completeness; not load-bearing without a file backend). `LogLevel debug2` was
  already set. `cupsd -t` = OK (only the expected `pstops`/`rastertopwg` "Filter
  not found" warnings).
- Removed the leftover `printers.conf` (the spike-2 `test` socket queue) so the
  new queue is the only one. Re-created runtime dirs (`var/spool/tmp`, `var/run`,
  `var/log`, `var/cache`, `etc/cups/ppd`). Tree from spike 2 was still intact —
  no re-push needed.

### Exact steps (all on device, run as `shell`, env
`LD_LIBRARY_PATH=/data/local/tmp/cupstest/lib CUPS_SERVER=127.0.0.1:10631`):
```
# boot (same known-good command as spike 2)
cd /data/local/tmp/cupstest && LD_LIBRARY_PATH=.../lib nohup ./sbin/cupsd -f \
  -c .../etc/cups/cupsd.conf -s .../etc/cups/cups-files.conf >.../var/log/cupsd.stdout 2>&1 &
./bin/lpstat -r                                 # -> "scheduler is running"

# start a capture listener (toybox nc) that writes the raw stream to a file
nohup nc -s 127.0.0.1 -p 9101 -l > /data/local/tmp/cupstest/var/out.prn 2>... &

# RAW queue -> the listener; submit the test file
printf 'HELLO_CUPS_ANDROID_JOB\n' > .../var/in.txt
./bin/lpadmin -h 127.0.0.1:10631 -p filetest -E -v socket://127.0.0.1:9101 -m raw
./bin/lp -h 127.0.0.1:10631 -d filetest -o raw .../var/in.txt   # -> request id is filetest-1
./bin/lpstat -W completed -o                    # -> filetest-1 ... 1024 ...  (completed)
cat .../var/out.prn                             # -> HELLO_CUPS_ANDROID_JOB   (23 bytes)
```

### out.prn contents (the success bar)
```
HELLO_CUPS_ANDROID_JOB      (23 bytes = the 22-char string + newline)  <-- PASS
```

### Decisive error_log lines (debug2)
```
[Job 1] Sending job to queue tagged as raw...
filetest: File ".../backend/socket" permissions OK (0100755/uid=2000/gid=2000).
cupsdStartProcess(command=".../backend/socket", argv=..., infd=-1, outfd=-1,
   errfd=11, backfd=13, sidefd=15, root=0, profile=0x0, job=...(1), ...) = 30135
[Job 1] Started backend .../backend/socket (PID 30135)
[Job 1] Connecting to 127.0.0.1:9101
[Job 1] Print file sent.
[Job 1] PID 30135 (.../backend/socket) exited with no errors.
```

### How the backend is actually launched — `cups-exec` is NOT used
The single most important line is `profile=0x0` in `cupsdStartProcess`, and
`argv[0]` being the device URI (`socket://...`), NOT `.../daemon/cups-exec`.
Tracing the source (`scheduler/process.c`, `scheduler/job.c`, `config.h`):
- `config.h`: `HAVE_SANDBOX_H` is **#undef** and `HAVE_POSIX_SPAWN` is **#undef**
  (bionic has posix_spawn, but CUPS's configure didn't detect/enable it here).
- `cupsdCreateProfile()` is entirely wrapped in `#ifdef HAVE_SANDBOX_H`; on
  Android it falls through to the `#else` that returns `NULL`. So
  `job->profile` and `job->bprofile` are both NULL for every job.
- In `cupsdStartProcess`, the `cups-exec` wrapper is inserted only inside
  `#if !USE_POSIX_SPAWN { if (profile) { ... real_argv[0]=cups-exec ... } }`.
  With `USE_POSIX_SPAWN == 0` (no posix_spawn) AND `profile == NULL`, that block
  is skipped -> the backend is exec'd **directly** via the classic
  `fork()` + `execv()` path. (No "Calling posix_spawn" line appears in the log,
  confirming the fork path.)
- Net: on Android, cupsd spawns filters/backends with a plain non-root
  `fork`+`execv` (uid/gid stay `shell` 2000, which is already the cupsd uid, so
  no setuid is attempted). `cups-exec` and the macOS `sandbox_init` profile
  machinery are dead code in this build. The reviewer's cups-exec concern does
  not apply.

### SELinux findings — NO denials
- `dmesg | grep avc` -> empty (non-root `shell` cannot read the kernel ring
  buffer; expected, not evidence of denial).
- `logcat -d | grep -iE 'avc|denied|cups'` -> only unrelated UI/system noise
  (`vendor.mpctl.init.complete` property reads) + our own adb command echoes.
  NO `avc: denied` for cupsd/socket/nc/fork/exec. The `shell` domain permits
  fork/exec of files under `/data/local/tmp` and loopback TCP connect/listen,
  which is the whole pipeline. Job ran clean end to end.

### BONUS — non-raw text print (filter chain)
Submitting WITHOUT `-o raw` auto-typed the input as `text/plain`
(`[Job 2] Request file type is text/plain`) but the queue itself is a **raw
queue**, so cupsd logged `Sending job to queue tagged as raw...` and again
bypassed all filters straight to the socket backend (out2.prn =
`HELLO_CUPS_ANDROID_JOB`). So a real filter chain was NOT exercised — would need
a non-raw queue with a PPD/driver, which we have neither of yet.

### Filter inventory (informs next phase)
- On device `lib/cups/filter/` is **EMPTY** — zero filters were pushed. That is a
  STAGING gap, not a build gap.
- The CUPS-core filters DID build fine as AArch64 binaries in the build tree
  (`tool/android/build/cups-2.4.19/filter/`): `commandtops, gziptoany, pstops,
  rastertoepson, rastertohp, rastertolabel, rastertopwg` (all verified
  `ELF AArch64 PIE`). `stage.sh` just never copies them: it makes the
  `lib/cups/filter` dir but its staging loop only iterates backends/daemons.
  **Fix for next phase:** extend `stage.sh` to copy the built filters; then
  re-push. (`gziptoany` in particular is the universal raw/gz pass-through used
  by every queue.)
- Filters we still DON'T have (not in CUPS core tree — they live in the separate
  `cups-filters`/`libcupsfilters` + Ghostscript stack): `pdftops`, `texttopdf`,
  `texttops`, `imagetops`, `imagetoraster`, `bannertopdf`, the
  PDF/PWG/PCLm/URF rasterizers. A normal `text/plain` or `application/pdf` job to
  a real driver needs these. Building `cups-filters` for Android (pulls in
  poppler/qpdf/ghostscript or the libppd path) is the next large unknown.

### Errors hit + fixes
- file backend missing -> switched to socket backend + nc listener (above). Only
  real deviation from the plan; proves the identical mechanism.
- chained `./bin/lpstat` calls within one `adb shell` lost `LD_LIBRARY_PATH`
  (`CANNOT LINK EXECUTABLE ... libcups.so.2 not found`) -> cosmetic; set the env
  on each invocation.

### Cleanup
cupsd + nc killed, port 10631/9101 freed. `/data/local/tmp/cupstest` tree +
logs + out.prn/out2.prn left in place for inspection. Nothing outside
/data/local/tmp touched; no reboot.

### Bottom line
PASS. A print job's bytes reach the backend's device output on non-rooted,
SELinux-enforcing Android. cups-exec is NOT on the path (compiled out); cupsd
uses plain `fork`+`execv` as the `shell` uid with no sandbox and no denials.
Remaining work for non-raw printing is the FILTER stack (stage the already-built
core filters; build `cups-filters` for the PDF/raster paths) — not the spawn
mechanism.

## App packaging (static libcups + jniLibs)

**Goal:** bundle CUPS *inside the Flutter app* (not /data/local/tmp), so it ships
with the APK. **STATUS: SUCCESS** — libcups/libcupsimage are now STATIC-linked
into every executable, eliminating Android's versioned-`.so` packaging problem.

### The problem
Android's APK packaging (AGP) + the dynamic loader only handle libraries named
exactly `lib*.so` — **no version suffix**. The original spike built
`libcups.so.2` (SONAME `libcups.so.2`) and `cupsd`/backends recorded
`NEEDED libcups.so.2`. AGP won't package `.so.2`, and even if it did the loader
couldn't find it. So a shared libcups cannot be bundled as-is.

### Fix: STATIC-link libcups (chosen approach — clean, no patching)
CUPS 2.4.x's own build system fully supports this. Passing
`--disable-shared --enable-static` makes `config-scripts/cups-sharedlibs.m4` set:
```
LIBCUPS      = libcups.a            LIBCUPSIMAGE = libcupsimage.a
LINKCUPS     = ../cups/libcups.a $(LIBS)     DSO = ":"     PICFLAG = 0
```
Every executable links via `$(LINKCUPS)` (verified in scheduler/backend/filter
Makefiles), so `cupsd` + all backends + all daemon helpers + all filters link
the `.a` **directly** and become self-contained. No `libcups.so*` is produced,
so there is nothing versioned to package. No SONAME/NEEDED patching, no
`patchelf` (which is NOT installed here anyway — `which patchelf` = not found),
no `llvm-objcopy` rename hacks. This is why static was preferred over the
rename-`.so` fallback.

### Exact build command
```
CUPS_LINK=static tool/android/build-cups.sh clean     # full static build
CUPS_LINK=static tool/android/build-cups.sh           # incremental
CUPS_LINK=shared tool/android/build-cups.sh clean     # legacy shared (reference)
```
`CUPS_LINK` defaults to **static**. The script records the mode in a stamp file
(`build/cups-2.4.19/.cups-link-mode`) and auto-reconfigures + rebuilds if the
mode flips (the static/shared choice is baked into Makedefs at configure time).
`stage.sh` is mode-aware: static mode stages `libcups.a`/`libcupsimage.a` + the
cups public headers (and removes any stale `.so`); shared mode stages the
`.so.2` + dev symlinks. Both modes now also stage the built core filters
(gziptoany/pstops/rastertopwg/... — fixes the spike-2b staging gap).

### readelf verification — NO `NEEDED libcups.so.2` anywhere
`llvm-readelf -d` over every staged executable. The only NEEDED libs are bionic
(present on every device) plus `libc++_shared.so` for `cups-driverd` (it links
the C++ ppdc lib — the one non-bionic dep; see below). cupsd:
```
$ llvm-readelf -d out/arm64/sbin/cupsd | grep -iE 'NEEDED|cups'
  (NEEDED)  Shared library: [libm.so]
  (NEEDED)  Shared library: [libz.so]
  (NEEDED)  Shared library: [libdl.so]
  (NEEDED)  Shared library: [libc.so]
  # NO libcups.so.2 — statically linked in. (was: NEEDED libcups.so.2)
```
Full unique NEEDED set across ALL executables (cupsd, 6 backends, 5 daemons,
7 filters, lp/lpadmin/lpstat):
```
libc.so  libdl.so  libm.so  libz.so  libc++_shared.so
```
`libc++_shared.so` appears for exactly ONE binary: `cups-driverd`. Every other
binary is bionic-only.

### file(1) / readelf -h — still AArch64 PIE
```
$ file out/arm64/sbin/cupsd
ELF 64-bit LSB pie executable, ARM aarch64, interpreter /system/bin/linker64, not stripped
$ llvm-readelf -h out/arm64/sbin/cupsd | grep -E 'Class|Type|Machine'
  Class:   ELF64
  Type:    DYN (Shared object file)      # DYN + PT_INTERP = PIE
  Machine: AArch64
```
(Same for backends, daemons, filters — all AArch64 PIE.)

### Static archive sanity — full API present
```
$ llvm-nm out/arm64/lib/libcups.a | grep ' T '   # all exported:
cupsGetPPD  cupsPrintFile  cupsDoRequest  cupsGetDests  ippNew  ppdOpenFile  ...
$ llvm-ar t out/arm64/lib/libcups.a | wc -l       # 60 objects archived
```

### jniLibs naming map (full map in jnilibs-map.md)
Copied each executable into `example/android/app/src/main/jniLibs/arm64-v8a/`
renamed to `lib*.so` so AGP packages them (and `useLegacyPackaging = true`,
already set in the example app's build.gradle.kts, extracts them to
`nativeLibraryDir` where they're exec'able). Convention:
- scheduler `cupsd` -> `libcupsd.so`
- backend `<name>` -> `libcupsbe_<name>.so` (socket/ipp/lpd/snmp/usb/http)
- daemon  `cups-<name>` -> `libcupsd_<name>.so` (deviced/driverd/exec/lpd; cupsfilter -> libcupsd_cupsfilter.so)
- filter  `<name>` -> `libcupsf_<name>.so` (gziptoany/pstops/commandtops/rastertopwg/rastertoepson/rastertohp/rastertolabel)
- client  `<name>` -> `libcupstool_<name>.so` (lp/lpadmin/lpstat)
- NDK C++ runtime -> `libc++_shared.so` (verbatim; cups-driverd needs it)
23 files total (22 CUPS binaries + libc++_shared.so). The app builds a runtime
SYMLINK FARM mapping cupsd's canonical
`serverbin/{backend,filter,daemon}/<name>` paths to these `lib*.so` (see
jnilibs-map.md for the exact symlink list). That symlink-farm + cupsd-launch
wiring is a SEPARATE later task (not done here).

### Header / static-lib / data staging (locations + sizes)
All under `tool/android/out/arm64/`:
- `include/cups/*.h` — 32 cups public headers (cups.h, ppd.h, http.h, ipp.h,
  raster.h, array.h, file.h, language.h, transcode.h, ...) — **316 KB**.
  (FFI C will `#include <cups/cups.h>` and link the static lib.)
- `lib/libcups.a` — **4.2 MB** (unstripped; full classic 2.x API incl. PPD).
- `lib/libcupsimage.a` — **48 KB**.
- `share/cups/mime/{mime.types,mime.convs}` — **12 KB** (needed to boot cupsd).
- `share/cups/data/*` (font.defs, media.defs, raster.defs, ppdc headers, ...) —
  **48 KB**.
- Runtime data the app ships as assets (mime + data) = **~60 KB total**.

### Bundled size
- jniLibs (23 `lib*.so`, unstripped) = **34 MB** in the working tree; AGP strips
  `.so` during packaging -> **~9 MB** in the APK (measured with
  `llvm-strip --strip-unneeded`). arm64-v8a only.
- `out/arm64/` total (libs + headers + bins + data) = **44 MB** (unstripped).

### Unresolved / deferred (NOT blockers for this packaging task)
- **cups-driverd needs `libc++_shared.so`** — bundled into jniLibs. AGP would
  normally add it anyway (app already has C++ via the CMake externalNativeBuild),
  but it's staged explicitly to be safe. The other 22 binaries are bionic-only.
- Binaries are **not stripped** (carry debug_info). AGP strips jniLibs at
  package time; strip manually with `llvm-strip` if shipping the raw tree.
- The **runtime symlink farm + cupsd launch from nativeLibraryDir** is the next
  task (touches MainActivity.kt / Dart / src/printing_ffi.c — intentionally NOT
  touched here per task constraints).
- TLS still off (no ipps/https), DNS-SD off (no dnssd backend) — same as the
  shared spike; unchanged by the static switch.
- Non-raw print still needs the broader `cups-filters` stack (pdftops, the
  PDF/PWG rasterizers) — separate large unknown, unchanged here. The CUPS-core
  filters (gziptoany etc.) are now staged + bundled.

## Phase 1 app integration

**RESULT: PASS (milestone + bonus).** The example app boots the bundled `cupsd`
from inside its own app sandbox at the app uid, the plugin's libcups FFI client
does an IPP `get_printers` round-trip against it (empty list, no error = the
success bar), AND a new `add_cups_printer` FFI creates a raw `socket://` queue
that `get_printers` then lists. All on the non-rooted Samsung S25 (API 36).

### What was wired (files changed)
- `pubspec.yaml`: added `android: { ffiPlugin: true }` so Flutter builds
  `src/CMakeLists.txt` for Android and bundles `libprinting_ffi.so`.
- `src/CMakeLists.txt`: in the `if(ANDROID)` branch, link the staged static CUPS
  (`tool/android/out/arm64/lib/libcups.a` + `libcupsimage.a`) + `z m dl log`, and
  add `tool/android/out/arm64/include` to the include path. Guarded to
  `ANDROID_ABI == arm64-v8a` (FATAL_ERROR otherwise — only arm64 CUPS was built).
  Desktop branches untouched. `-llog` is required (Android logging).
- `android/build.gradle` (PLUGIN module): added
  `defaultConfig { ndk { abiFilters "arm64-v8a" } }`. WITHOUT this the plugin's own
  Gradle module still configures CMake for armeabi-v7a/x86/... and hits the
  FATAL_ERROR. The app-module abiFilters alone is NOT enough.
- `example/android/app/build.gradle.kts`: `ndk { abiFilters += "arm64-v8a" }`;
  removed the spike externalNativeBuild; kept `useLegacyPackaging = true`.
- `src/printing_ffi.h/.c`: new FFI exports `start_cups_server`,
  `stop_cups_server`, `add_cups_printer` (Android-guarded launcher + IPP add).
  Also: Android `LOG` -> `__android_log_print` (tag `PrintingFfiCups`),
  `open_printer_properties` returns 0 on Android (no xdg-open).
- `lib/printing_ffi_bindings_generated.dart`: hand-added bindings for the 3 funcs.
- `lib/printing_ffi.dart`: `_dylib` opens `libprinting_ffi.so` on Android; added
  `startCupsServer` / `stopCupsServer` / `addCupsPrinter` wrappers + `_getLastError`.
- `example/android/.../MainActivity.kt`: rewritten to a MethodChannel
  (`printing_ffi/cups`, method `getCupsPaths`) returning
  `nativeLibDir` (= applicationInfo.nativeLibraryDir),
  `serverRoot` (= filesDir/cups), `dataDir` (= filesDir/cupsdata), and extracting
  the bundled `share/cups/{mime,data}` assets.
- `example/android/app/src/main/assets/cups/share/cups/{mime,data}`: the runtime
  data, copied from `tool/android/out/arm64/share/cups`, shipped as app assets.
- `example/lib/cups_android_boot.dart` (new) + `example/lib/main.dart`: on Android
  at startup, fetch paths, `start_cups_server`, `get_printers`, show a banner +
  an "Add raw socket:// queue" button (calls `add_cups_printer` then re-lists).

### How start_cups_server works (the launcher, in C, on Android)
1. `getuid()`/`getgid()` -> writes NUMERIC identity into `cups-files.conf`
   (`User #<uid>` / `Group #<gid>` / `SystemGroup #<gid>`). This is the KNOWN HARD
   PART and it WORKED first try: at the app uid there's no passwd name, but cupsd
   is non-root (never setuids) and `User #<uid>` parses + matches the current uid,
   so no privilege drop is attempted. No name resolution needed.
2. Creates runtime dirs under serverRoot: `etc/cups`(+`ppd`), `sbin` (=ServerBin),
   `var/spool`(+`tmp`), `var/run`, `var/cache`, `var/log`.
3. Builds the ServerBin SYMLINK FARM under `sbin/{backend,filter,daemon}/<name>`
   -> `nativeLibraryDir/lib*.so` per `jnilibs-map.md` (verified resolves on device).
4. Picks an ephemeral free localhost port via `bind(127.0.0.1:0)` + getsockname.
5. Writes `cupsd.conf` (Listen 127.0.0.1:<port>, TCP-only, Browsing Off,
   DefaultAuthType None, WebInterface No, permissive Location/Policy) and
   `cups-files.conf` (ServerRoot/ServerBin/DataDir/RequestRoot/StateDir/CacheDir/
   TempDir/logs + numeric identity + FileDevice Yes). DataDir = `<dataDir>/share/cups`.
6. `fork()` + `execv(nativeLibraryDir/libcupsd.so, "-f -c ... -s ...")`.
7. Polls `connect(127.0.0.1:<port>)` until cupsd answers (bails if child dies),
   then `cupsSetServer("127.0.0.1:<port>")` + `setenv CUPS_SERVER` so the existing
   libcups client targets the in-app cupsd. Returns the port.
`stop_cups_server` SIGTERMs the child, waits, SIGKILLs if needed, reaps.

### add_cups_printer
CUPS-Add-Modify-Printer IPP op against the current server (the in-app cupsd):
sets `device-uri`, `printer-state=idle`, `printer-is-accepting-jobs=true`,
`ppd-name=raw` (for a raw queue). Returns true on `successful-ok`.

### Decisive logcat (tag PrintingFfiCups)
```
start_cups_server: uid=10070 gid=10070 ...
start_cups_server: forked cupsd pid=995 on 127.0.0.1:46209
start_cups_server: SUCCESS, cupsd up on 127.0.0.1:46209 (client targeted)
get_printers (after boot): 0 printer(s) -> []                       # MILESTONE
add_cups_printer: SUCCESS for 'test'
get_printers (after add): 1 printer(s) -> [test@socket://192.0.2.1:9100]  # BONUS
```
cupsd error_log: `Listening to 127.0.0.1:46209` / `Full reload complete` /
`Scheduler started in foreground` / `CUPS-Add-Modify-Printer ... successful-ok` /
`Setting test device-uri to "socket://192.0.2.1:9100"`. access_log:
`POST /admin/ HTTP/1.1 200 ... CUPS-Add-Modify-Printer successful-ok`.

### Build gotchas (resume hints)
- Need `-llog` in the android CMake link line (`__android_log_print`).
- Restrict BOTH the plugin module (`android/build.gradle`) AND the example app to
  `arm64-v8a` via `ndk { abiFilters }`, else CMake configures for unbuilt ABIs and
  the FATAL_ERROR fires.
- Build/install/run: `cd example && flutter build apk --debug --target-platform
  android-arm64`; `adb -s RFCY90BL8GH install -r build/app/outputs/flutter-apk/app-debug.apk`.
- Pull on-device cupsd logs: `adb -s RFCY90BL8GH shell run-as
  com.example.printing_ffi_example cat files/cups/var/log/error_log`.

### Non-blocking observations
- Debug build shows a 16KB-page-size WARNING dialog: the bundled CUPS `lib*.so`
  were not linked with `-Wl,-z,max-page-size=16384` (only `libprinting_ffi.so` is).
  It is a warning overlay only; the app runs and the round-trip succeeds. For a
  release build, add that LDFLAG to `build-cups.sh` and re-stage jniLibs.
- error_log's `Unknown default SystemGroup "wheel"` is cupsd's compiled-in default,
  not our config; harmless. `banners` dir missing is harmless (none shipped).
- Job execution / real filter chain is unchanged from spike 2b (out of scope here).

## 16KB page alignment

**RESOLVED** the spike-1 "16KB-page-size WARNING dialog" (above): every bundled
CUPS executable is now linked 16384-byte page-aligned, so the LOAD segments load
cleanly on Android 15+/16KB-page devices and pass Google Play's check. Previously
only `libprinting_ffi.so` had the flag; the cross-built CUPS binaries were 0x1000.

### Flag added (`build-cups.sh`)
The NDK linker (lld) defaults to a 4096 (`0x1000`) max-page-size for arm64. We add
it to the cross env `LDFLAGS` so configure threads it into `LDFLAGS` in `Makedefs`,
and `ALL_LDFLAGS = -L../cups $(LDFLAGS) ...` carries it onto EVERY executable's link
line (`cupsd` + all 6 backends + 5 daemon helpers + 7 filters + lp/lpadmin/lpstat).
Static `.a` archives are not linked so they're unaffected.
```
export LDFLAGS="-Wl,-z,max-page-size=16384"
```
Verified captured: `Makedefs` now has `LDFLAGS = -Wl,-z,max-page-size=16384`.

### Rebuild + re-stage
```
tool/android/build-cups.sh clean          # static (default); re-runs configure with new LDFLAGS, builds, runs stage.sh -> out/arm64/
# then copy each out/arm64 binary into jniLibs under its lib*.so name (per jnilibs-map.md):
#   sbin/cupsd                 -> jniLibs/arm64-v8a/libcupsd.so
#   lib/cups/backend/<name>    -> libcupsbe_<name>.so   (socket ipp lpd snmp usb http)
#   lib/cups/daemon/cups-<n>   -> libcupsd_<n>.so       (deviced driverd exec lpd; cupsfilter -> libcupsd_cupsfilter.so)
#   lib/cups/filter/<name>     -> libcupsf_<name>.so    (gziptoany pstops commandtops rastertopwg rastertoepson rastertohp rastertolabel)
#   bin/<tool>                 -> libcupstool_<tool>.so (lp lpadmin lpstat)
```
`libc++_shared.so` is NDK-supplied and already 0x4000-aligned (NDK 27), so it is
NOT rebuilt/recopied. All 23 staged `jniLibs/arm64-v8a/*.so` now report 0x4000.

### Verification (NDK `llvm-readelf -l`, on the STAGED jniLibs)
```
$ llvm-readelf -l example/android/app/src/main/jniLibs/arm64-v8a/libcupsd.so
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x039c80 0x039c80 R   0x4000
  LOAD           0x039c80 0x000000000003dc80 0x000000000003dc80 0x078ac0 0x078ac0 R E 0x4000
  LOAD           0x0b2740 0x00000000000ba740 0x00000000000ba740 0x006ed0 0x0078c0 RW  0x4000
  LOAD           0x0b9610 0x00000000000c5610 0x00000000000c5610 0x0001fc 0x000f30 RW  0x4000

$ llvm-readelf -l example/android/app/src/main/jniLibs/arm64-v8a/libcupsbe_socket.so
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x025028 0x025028 R   0x4000
  LOAD           0x025028 0x0000000000029028 0x0000000000029028 0x0401d8 0x0401d8 R E 0x4000
  LOAD           0x065200 0x000000000006d200 0x000000000006d200 0x005d38 0x005e00 RW  0x4000
  LOAD           0x06af38 0x0000000000076f38 0x0000000000076f38 0x000024 0x008588 RW  0x4000
```
Every LOAD segment `Align` is now `0x4000` (16384), was `0x1000` (4096). An audit
of all 23 staged `*.so` reported 0 files with any `0x1000` LOAD segment.
