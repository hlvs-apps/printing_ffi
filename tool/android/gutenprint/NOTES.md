# Gutenprint 5.3.x cross-compile for Android arm64 — build notes

Feasibility spike (BUILD-ONLY): cross-compile Gutenprint for Android arm64 with
the NDK, against the already-staged cross CUPS, to learn whether the CUPS raster
filter `rastertogutenprint` (and the DNP dye-sub backend) build, and to map the
dependency tree. **STATUS: PASS** for `rastertogutenprint` (+ library + driver
data + dye-sub command filter). **The DNP USB backend is NOT built** — it needs
libusb-1.0 cross-compiled (deliberately skipped this pass; see below).

NOT integrated into the app. Nothing here touches the plugin, the example app,
`build-cups.sh`, or the read-only CUPS staging in `../out/arm64/`.

## Version / source
- Gutenprint **5.3.5** — latest 5.3.x release (released 2025-03-12).
- Tarball (ships a ready `./configure`, no autogen):
  `https://downloads.sourceforge.net/project/gimp-print/gutenprint-5.3/5.3.5/gutenprint-5.3.5.tar.xz`
  (mirror of SourceForge `gimp-print` project; page:
  https://sourceforge.net/projects/gimp-print/files/gutenprint-5.3/5.3.5/)
- SHA-256: `f5a9f47de28530b1ae2069cfbc647a9a641baeeabe809bb0ef2b3ec5b9668d70`
- ABI: **aarch64-linux-android**, **API 24**, NDK 27
  (`/Users/henrisauer/Library/Android/sdk/ndk/27.0.12077973`, clang 18.0.1).
  Same toolchain/env recipe as `../build-cups.sh`.

## How to build
```
tool/android/build-gutenprint.sh            # incremental (idempotent)
tool/android/build-gutenprint.sh clean      # wipe src + out, reconfigure
RECONFIGURE=1 tool/android/build-gutenprint.sh   # force reconfigure, keep src
```
The script: sets the clean cross env (overrides host-polluted flags), downloads
+caches the tarball, extracts, restores the shipped `xmli18n-tmp.h` if a prior
failed run deleted it, applies patches (stamped/idempotent), materializes a
`cups-config` shim pointing at the staged CUPS, configures (only if needed),
`make -j`, then stages outputs + verifies AArch64 via `stage-gutenprint.sh`.

## Files (all under tool/android/, scoped to this spike)
- `build-gutenprint.sh` — env + download + configure + build + stage. Re-runnable.
- `gutenprint/stage-gutenprint.sh` — copies artifacts into `out/arm64-gutenprint/`
  and runs the `file`/`readelf` AArch64 verification.
- `gutenprint/cups-config-android.in` — template for the `cups-config` shim
  (`@STAGED_CUPS@` substituted at build time). See "CUPS hookup" below.
- `gutenprint/android-compat-gp.h` — force-included (`-include`) bionic shim
  (iconv stubs for API < 28). See "Patches / shims".
- `gutenprint/patches/0001-cross-skip-extract-strings-host-run.patch` — the one
  source patch (a Makefile.in fix). See "Patches / shims".
- `gutenprint/build/` — extraction + build tree (gitignore-able).
- `gutenprint/cache/` — downloaded tarball.
- `gutenprint/logs/` — configure.log, build.log.
- `out/arm64-gutenprint/` — staged deliverables.

## Final configure flags
```
--host=aarch64-linux-android
--prefix=/system/gutenprint
--with-cups=<repo>/tool/android/out/arm64        # staged CUPS prefix
--with-cups-config=<repo>/tool/android/gutenprint/cups-config-android
--disable-nls              # no gettext/iconv translation machinery
--disable-cups-ppds        # *critical for cross*: do NOT RUN arm64 cups-genppd
--disable-test             # test programs (some run target binaries)
--disable-samples
--disable-escputil
--without-gimp2            # no GIMP plugin (needs gtk/gimp)
--disable-libgutenprintui2 # no GTK UI lib
--without-readline
--without-doc              # no docbook build
--disable-shared --enable-static   # static libgutenprint; forces static modules
```
IMPORTANT flag notes:
- There is **NO `--disable-libusb1`** flag (the task guessed one). libusb-1.0 is
  auto-detected via `PKG_CHECK_MODULES([LIBUSB],[libusb-1.0],...)`. We suppress it
  by pointing pkg-config at an EMPTY libdir (see host-env de-pollution), so
  `BUILD_LIBUSB_BACKENDS=no` and the whole `backend_gutenprint` (which contains
  `backend_dnpds40.c`) is skipped by construction.
- `--disable-cups-ppds` is the single most important cross flag. Without it,
  `make` runs the *freshly-built aarch64* `cups-genppd` binary ON THE X86_64 HOST
  to generate PPD files (`src/cups/Makefile.am`: `all-local -> ppd-stamp ->
  ./cups-genppd.5.3 ...`). That aarch64 binary cannot execute on macOS. Disabling
  cups-ppds removes that `all-local` step; `cups-genppd` still *compiles* (we
  stage the binary), we just never RUN it. PPDs are runtime data — generate them
  on-device later (`cups-genppd -a -p <dir>`) or ship prebuilt.
- `--disable-shared --enable-static` makes Gutenprint's drivers (escp2, canon,
  pcl, ps, **dyesub**) compile directly INTO `libgutenprint.a` (WITH_MODULES is
  forced to `static`; no dlopen `.so` driver modules). rastertogutenprint then
  statically links the whole thing -> self-contained binary, no runtime module
  path to wire up.

## CUPS hookup (the interesting bit)
Gutenprint's `m4local/stp_cups.m4` (`STP_CUPS_LIBS`) runs `cups-config` to learn
CUPS CFLAGS/LIBS. The real cups-config in the CUPS build tree points at the
on-device install prefix (`/system/cups`) and emits a *shared* `-lcups`, but our
staged CUPS is **static-only** (`libcups.a`/`libcupsimage.a`). So we feed a
tailored `cups-config-android` shim via `--with-cups-config` that:
- `--cflags` -> `-I<staged>/include`
- `--image --libs` -> `<staged>/lib/libcupsimage.a <staged>/lib/libcups.a -lz -lm`
  (absolute static-archive paths, libcupsimage before libcups for static order;
  both archives contain the raster API, so cupsRasterOpen etc. resolve).
- runtime paths (`--serverbin`/`--datadir`/`--serverroot`) report the on-device
  `/system/cups` layout (informational only for this build).

Result: `rastertogutenprint` **statically embeds** the CUPS client + raster API
(verified: `cupsRasterReadHeader`, `_cupsRasterNew`, etc. are `T` symbols in the
binary; no CUPS lib is `NEEDED`).

## Patches / shims (minimal, documented)
1. **patches/0001-cross-skip-extract-strings-host-run.patch** (src/xml/Makefile.in)
   - `src/xml/extract-strings` is compiled aarch64 but the Makefile then RUNS it
     on the host to regenerate `src/xml/xmli18n-tmp.h` (an NLS string table):
     `./extract-strings: cannot execute binary file`.
   - The tarball already SHIPS a generated `xmli18n-tmp.h` (6908 lines), consumed
     only by `po/*.po` at *dist* time — nothing in a `--disable-nls` build
     `#include`s it. The patch drops it from CLEANFILES (so the shipped copy
     survives) and replaces the recipe with a cross-safe no-op (keep the shipped
     header; empty placeholder if absent). `extract-strings` still compiles as a
     `noinst_PROGRAM` (harmless aarch64 link) but is never a prerequisite -> never
     run. Patched against `Makefile.in` so it survives `./configure`.

2. **android-compat-gp.h** (force-included via `-include`)
   - bionic's `<iconv.h>` DEFINES `iconv_t` at all API levels but DECLARES
     `iconv_open`/`iconv`/`iconv_close` only `__INTRODUCED_IN(28)`. Gutenprint's
     `src/cups/i18n.c` calls all three at API 24 -> implicit-int declaration ->
     `error: incompatible integer to pointer conversion ... iconv_open(...)`.
   - i18n.c uses iconv only to transcode `.po` message-catalog charsets to UTF-8,
     and it ALREADY falls back to using the string verbatim when `iconv_open`
     returns `(iconv_t)-1`. We build `--disable-nls` and .po charsets are almost
     always UTF-8, so verbatim is correct. The shim provides `static inline`
     stubs (macro-mapped onto the real names) that make `iconv_open` report
     "unsupported" -> i18n.c takes the safe no-transcode path. `static inline` =>
     no new link symbols, no Makefile edits. Active only on `__ANDROID__ &&
     __ANDROID_API__ < 28`.

## Host environment pollution (same gotcha as the CUPS build)
`~/.zshrc` exports `LDFLAGS=-L/usr/local/opt/ruby/lib`,
`CPPFLAGS=-I/usr/local/opt/ruby/include`,
`PKG_CONFIG_PATH=...qt@5...` into every shell, and Homebrew has an **x86_64**
libusb-1.0 installed. `build-gutenprint.sh` OVERRIDES (not appends)
CFLAGS/CPPFLAGS/LDFLAGS/LIBS, sets `PKG_CONFIG_PATH=""` and
`PKG_CONFIG_LIBDIR=<empty dir>` so pkg-config discovers NO host library. This is
also what makes the libusb-1.0 check fail (-> no DNP/dye-sub USB backend) without
breaking the pkg-config presence/version check (do NOT set `PKG_CONFIG=false` —
that fails configure's version test).

## Dependency + license map  (THE key deliverable)

| Component | Built? | Deps | License |
|---|---|---|---|
| **libgutenprint.a** (core lib + all drivers incl. `print-dyesub.o`) | YES | `-lm` only (bionic). NO zlib/tiff/jpeg/png/libusb. | GPL-2.0+ |
| **rastertogutenprint.5.3** (CUPS raster filter) | **YES** | staged CUPS (`libcups.a`+`libcupsimage.a`, static-embedded) + libgutenprint.a + `-lm`. Runtime NEEDED: `libz libm libdl libc` (all bionic). | GPL-2.0+ |
| **commandtodyesub / commandtoepson / commandtocanon** (CUPS command filters) | YES | `$(CUPS_LIBS)` only | GPL-2.0+ |
| **cups-genppd.5.3** (PPD generator) | YES (compiled; NOT run) | CUPS + libgutenprint + `-lz` | GPL-2.0+ |
| **gutenprint.5.3** (CUPS 1.2 driver interface) | YES | CUPS + libgutenprint | GPL-2.0+ |
| **cups-calibrate** | YES | `-lm` | GPL-2.0+ |
| **backend_gutenprint** (the combined dye-sub USB backend — contains `backend_dnpds40.c`, mitsu, kodak, shinko, sony, magicard, hiti, ...) | **NO** | **needs libusb-1.0** (pkg-config), + libdl/libltdl for module loading. Author: Solomon Peachy, `SPDX GPL-2.0+`. | GPL-2.0+ |

### Does the DNP backend need libusb cross-compiled?  **YES.**
The DNP protocol/handshake (`backend_dnpds40.c`) is one source file inside the
single `backend_gutenprint` binary that Gutenprint builds for ALL dye-sub USB
printers. It is gated entirely behind the autoconf conditional
`BUILD_LIBUSB_BACKENDS`, which is set only when `PKG_CHECK_MODULES(libusb-1.0)`
succeeds. `backend_gutenprint_LDADD = $(LIBUSB_LIBS) $(LIBUSB_BACKEND_LIBDEPS)`
and `_CPPFLAGS = ... $(LIBUSB_CFLAGS) -DLIBUSB_PRE_1_0_10`. So:
- **To build the DNP backend you MUST cross-compile libusb-1.0 for arm64 first**
  (LGPL-2.1, so it can be shipped/linked without infecting MIT code — but the
  BACKEND itself is GPL and must stay a separately-exec'd process, the license
  firewall). libusb on Android talks to USB devices via the Linux usbfs / the
  `UsbManager` file descriptor; a cross-build is a self-contained autotools job
  but was TIMEBOXED OUT of this build-only pass.
- Note the code passes `-DLIBUSB_PRE_1_0_10`; check libusb API compat when built.

### What rastertogutenprint (the FILTER) needs — NO image libraries
Confirmed by reading `configure.ac` (there is **no** libtiff/libjpeg/libpng/zlib
check anywhere) and `src/cups/rastertogutenprint.c` (includes only `cups/*.h`,
libc, `gutenprint/*.h`). The filter reads the **CUPS raster** stream (from
libcupsimage) and drives libgutenprint — it does NOT decode image files. So:
- **rastertogutenprint does NOT need libtiff / libjpeg / libpng.** (Those would
  only appear far upstream in the `cups-filters` PDF/image path, not here.)
- Its only external runtime lib beyond bionic is `libz` (pulled in transitively
  by libcups for gzip; present on every Android device).

## AArch64 verification (from the actual staged binaries)
### file(1)
```
rastertogutenprint.5.3 : ELF 64-bit LSB pie executable, ARM aarch64, interpreter /system/bin/linker64, not stripped
cups-genppd.5.3 / gutenprint.5.3 / commandto* / cups-calibrate : ELF 64-bit LSB pie, ARM aarch64
libgutenprint.a : current ar archive (member array.o -> ELF64 AArch64)
```
### llvm-readelf -h
```
rastertogutenprint.5.3 : Class ELF64, Type DYN (PIE), Machine AArch64
```
### 16KB page alignment (Android 15+/Play requirement)
LOAD segment Align = `0x4000` (16 KB) — the `-Wl,-z,max-page-size=16384` flag
took (matches build-cups.sh).
### Dynamic deps (NEEDED) — NO host taint, bionic + libz only
```
rastertogutenprint.5.3 : libz.so libm.so libdl.so libc.so
commandtodyesub        : libm.so libdl.so libc.so
```
Undefined dyn-syms are all `@LIBC` (bionic) plus `crc32/deflate*` (from libz.so).
No `/usr/local`, no Cellar, no host x86_64 libs.
### Embedded API check
`rastertogutenprint.5.3` embeds the CUPS raster API (`_cupsRasterNew`,
`cupsRasterReadHeader`, ...) and 552 `stp_*` Gutenprint symbols — fully
self-contained (CUPS + libgutenprint statically linked in).

## Staged tree (out/arm64-gutenprint/, ~20 MB unstripped)
```
lib/libgutenprint.a                         3.5 MB (50 objects; all drivers incl. print-dyesub.o)
cups/filter/rastertogutenprint.5.3          4.1 MB (self-contained CUPS raster filter)
cups/filter/commandto{dyesub,epson,canon}   ~8 KB each (CUPS command filters)
cups/backend/                               EMPTY  (DNP/dye-sub backend needs libusb — not built)
bin/cups-genppd.5.3                         (PPD generator; compiled, run on-device)
bin/gutenprint.5.3                          (CUPS 1.2 driver interface)
bin/cups-calibrate
include/gutenprint/*.h                       33 headers (for later FFI/link reference)
share/gutenprint/5.3/xml/                    6.6 MB, 326 .xml driver-data files
    printers/{canon,escp2,pcl,ps,dyesub,dpl,lexmark,raw}.xml   <- dyesub.xml = DNP models
    escp2/{inks,media,model,resolutions,weaves,...}/*.xml
    papers/, dither/
```
`dyesub.xml` (31 KB) references DNP models (DS40/DS620/DS820/QW410 etc.) — this is
the driver DATA that libgutenprint reads at runtime to render dye-sub output.
Outputs are NOT stripped (kept debug_info for the spike). `llvm-strip
--strip-unneeded` later for size.

## Driver-data size note
`share/gutenprint/5.3/xml` is **6.6 MB** (326 XML files). Most of that is the
Epson ESCP2 model/media/ink data (the `escp2/` subtree). Gutenprint loads this at
runtime; the exact set needed for a DNP-only deployment is a subset (at minimum
`printers/dyesub.xml` + `papers/` + `dither/` + the referenced base data). Pruning
to a DNP-only data set is a future optimization, not attempted here.

## What built vs what needs more
- BUILT & VERIFIED AArch64: `libgutenprint.a` (with the dye-sub renderer),
  `rastertogutenprint.5.3` (the goal filter), `commandtodyesub`/`commandtoepson`/
  `commandtocanon`, `cups-genppd.5.3`, `gutenprint.5.3`, `cups-calibrate`, and
  the 6.6 MB XML driver-data tree.
- NOT BUILT (documented finding, not a failure): `backend_gutenprint` (the
  combined dye-sub USB backend that holds `backend_dnpds40`) — requires
  cross-compiling **libusb-1.0** (LGPL-2.1) for arm64 first. TIMEBOXED out of this
  build-only pass per instructions.
- NOT RUN (by design): `cups-genppd` (would need to execute on the host, or on
  device). PPDs are runtime data; skip via `--disable-cups-ppds`.

## Open questions for the next session
1. **libusb-1.0 for arm64** — the one blocker for the DNP backend. It's an
   autotools cross-build (LGPL-2.1). On Android it needs the app to hand it a USB
   file descriptor from `UsbManager` (libusb has an Android "wrap sysdev" path);
   plan the device-access story alongside the cross-build.
2. **PPD generation** — run the staged `cups-genppd.5.3` on-device (or generate
   one specific DNP PPD) to feed cupsd's driver path. rastertogutenprint needs a
   matching PPD at runtime.
3. **Runtime data path** — libgutenprint expects its XML under
   `share/gutenprint/5.3/xml` (compiled-in `PKGXMLDATADIR=/system/gutenprint/...`);
   set `STP_DATA_PATH`/`STP_MODULE_PATH` env or relocate for the app sandbox.
4. **Data pruning** — 6.6 MB XML is Epson-heavy; a DNP-only subset would shrink it.
5. **License firewall** — all Gutenprint outputs are GPL-2.0+. They must remain
   separately-exec'd processes (filter/backend), never linked into the MIT plugin.

## libusb + DNP backend build

**STATUS: PASS.** The one thing missing from the original spike — `backend_gutenprint`
(the multi-call dye-sub USB backend that contains `backend_dnpds40.c`, the DNP
driver) — now **cross-compiles for arm64** with libusb-1.0 available. Verified
AArch64 PIE, DNP support embedded, libusb statically linked in.

### libusb-1.0 cross-build (the prerequisite)
- **libusb 1.0.27** (latest 1.0.x, released 2024-02; **LGPL-2.1-or-later** —
  safe to link/ship, does not infect the MIT plugin).
- Official release tarball `libusb-1.0.27.tar.bz2` (ships `./configure`, no autogen)
  from `https://github.com/libusb/libusb/releases/download/v1.0.27/`.
- Build script: `tool/android/build-libusb.sh [clean]` (re-runnable; same
  NDK 27 / aarch64 / API 24 toolchain + host-env de-pollution recipe as the
  other scripts). Stages to `tool/android/out/arm64-libusb/{lib,include,lib/pkgconfig}`.
- Configure flags: `--host=aarch64-linux-android --enable-static --enable-shared
  --disable-udev --disable-examples-build --disable-tests-build`.
  `--disable-udev` is **required on Android** (no libudev); libusb then builds its
  built-in Linux path (`os/linux_usbfs.lo` + `os/linux_netlink.lo`) which also
  carries the `libusb_wrap_sys_device()` fd-handoff support.
- Outputs: `libusb-1.0.a` (static), `libusb-1.0.so` (shared, SONAME
  `libusb-1.0.so`, NEEDED = libdl/libc only), `include/libusb-1.0/libusb.h`, and a
  rewritten `lib/pkgconfig/libusb-1.0.pc` (prefix/libdir/includedir point at the
  staged tree — this is what Gutenprint's `PKG_CHECK_MODULES` consumes).
- Verified AArch64: `file` -> "ELF 64-bit LSB shared object, ARM aarch64";
  `llvm-readelf -h` archive member + .so -> Class ELF64, Machine AArch64.
- **fd-handoff API present in 1.0.27**: `libusb_wrap_sys_device(libusb_context*,
  intptr_t sys_dev, libusb_device_handle**)` (libusb.h:1660) and
  `LIBUSB_OPTION_NO_DEVICE_DISCOVERY` (libusb.h:1530). These are what the next
  task uses for the Android `UsbManager` fd path.

### How build-gutenprint.sh now builds the DNP backend
`build-gutenprint.sh` was updated (no new flag required — auto-detects):
- Adds `STAGED_LIBUSB=$SCRIPT_DIR/out/arm64-libusb`. If
  `out/arm64-libusb/lib/pkgconfig/libusb-1.0.pc` + `libusb-1.0.a` exist (and
  `WITH_LIBUSB` != `0`), it **prepends ONLY that staged pkgconfig dir** to the
  otherwise-empty `PKG_CONFIG_LIBDIR`. So `PKG_CHECK_MODULES([LIBUSB],[libusb-1.0])`
  succeeds against the cross build (and NOTHING host leaks in) ->
  `BUILD_LIBUSB_BACKENDS=yes` -> `backend_gutenprint` is built. If libusb is not
  staged (or `WITH_LIBUSB=0`), it falls back to the original empty-libdir behaviour
  and the USB backend is skipped.
- Exports `LIBUSB_LIBS=<abs>/libusb-1.0.a` + `LIBUSB_CFLAGS=-I<abs>/include/libusb-1.0`
  so the backend **statically embeds** libusb (no runtime `NEEDED libusb-1.0.so`).
  (`PKG_CHECK_MODULES` alone would emit `-lusb-1.0`, which lld resolves to the .so;
  the explicit `.a` path forces the static archive.)
- **Reconfigure is required** to flip the `BUILD_LIBUSB_BACKENDS` autoconf
  conditional: run `RECONFIGURE=1 tool/android/build-gutenprint.sh` (or `clean`).
- `stage-gutenprint.sh` now stages the backend under BOTH the raw build name
  `backend_gutenprint` and the on-device install name `gutenprint53+usb` (the
  Makefile install-hook rename `gutenprint$(MAJOR)$(MINOR)+usb`), and runs the
  DNP-content + libusb-link verification below.

### Verification (from the actual staged backend)
`configure.log`: `checking for libusb-1.0... yes` / `Build CUPS dyesub USB backend: yes`.
```
file:    ELF 64-bit LSB pie executable, ARM aarch64, interpreter /system/bin/linker64
readelf -h: Class ELF64  Type DYN (PIE)  Machine AArch64
LOAD Align: 0x4000  (16 KB — Android 15+/Play requirement, matches other builds)
size:    ~538 KB (unstripped)
NEEDED:  libdl.so libm.so libc.so   (bionic only — NO libusb-1.0.so)
```
DNP support present (`strings | grep -i dnp`): `DNP 6x8`, `dnp-ds820`, `dnpds80dx`,
`dnpds820`, `dnp-ds620`, `dnp-ds80dx`, `DNP 5x7`, `dnp_citizen`, ...
DNP symbols (`nm`): `dnpds40_backend` (D), `dnpds40_attach`, `dnpds40_build_cmd`,
`dnp_combine_jobs`, `dnp_job_polarity`, `dnp_query_stats`, ...
libusb statically embedded (`nm | grep libusb`): `libusb_init`, `libusb_open`,
`libusb_get_device_list`, `libusb_wrap_sys_device`, `libusb_set_option`,
`libusb_open_device_with_vid_pid`, `libusb_init_context` — all `T` (in the binary).

Staged: `out/arm64-gutenprint/cups/backend/{backend_gutenprint, gutenprint53+usb}`
(previously EMPTY). The rest of the tree (rastertogutenprint, libgutenprint.a,
XML data, command filters) is unchanged.

### No extra deps beyond libusb
The backend links `$(LIBUSB_LIBS) $(LIBUSB_BACKEND_LIBDEPS)`. On Android
`LIBUSB_BACKEND_LIBDEPS` resolves to just `-ldl` (DLOPEN module loader —
`DLOPEN_LIBS`; libltdl is NOT needed/used). No `-lpthread` (bionic pthreads are in
libc), no libudev (`--disable-udev`). The backend links clean with only bionic +
the static libusb.a. NEEDED confirms: `libdl libm libc` only.
