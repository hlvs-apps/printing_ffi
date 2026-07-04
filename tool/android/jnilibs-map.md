# jniLibs naming map — CUPS executables bundled in the APK

Android's APK packaging + dynamic loader only handle files named exactly
`lib*.so` (NO version suffix). To ship the CUPS executables *inside the app*
(extracted to `nativeLibraryDir`, exec'able because `useLegacyPackaging = true`),
each binary is copied into `jniLibs/arm64-v8a/` under a `lib*.so` name.

Because libcups is **statically linked** into every executable (see NOTES.md
"App packaging"), there is NO `libcups.so` to package — each `lib*.so` below is a
self-contained PIE executable, not a real shared library.

Location: `example/android/app/src/main/jniLibs/arm64-v8a/`
Source tree: `tool/android/out/arm64/` (produced by `CUPS_LINK=static build-cups.sh`)

## Map: source binary -> jniLibs name

| CUPS role            | source (out/arm64/...)            | jniLibs name                  |
|----------------------|-----------------------------------|-------------------------------|
| scheduler            | `sbin/cupsd`                       | `libcupsd.so`                 |
| backend socket       | `lib/cups/backend/socket`          | `libcupsbe_socket.so`         |
| backend ipp          | `lib/cups/backend/ipp`             | `libcupsbe_ipp.so`            |
| backend lpd          | `lib/cups/backend/lpd`             | `libcupsbe_lpd.so`            |
| backend snmp         | `lib/cups/backend/snmp`            | `libcupsbe_snmp.so`           |
| backend usb          | `lib/cups/backend/usb`             | `libcupsbe_usb.so`            |
| backend http(->ipp)  | `lib/cups/backend/http`            | `libcupsbe_http.so`           |
| daemon cups-deviced  | `lib/cups/daemon/cups-deviced`     | `libcupsd_deviced.so`         |
| daemon cups-driverd  | `lib/cups/daemon/cups-driverd`     | `libcupsd_driverd.so`         |
| daemon cups-exec     | `lib/cups/daemon/cups-exec`        | `libcupsd_exec.so`            |
| daemon cups-lpd      | `lib/cups/daemon/cups-lpd`         | `libcupsd_lpd.so`             |
| daemon cupsfilter    | `lib/cups/daemon/cupsfilter`       | `libcupsd_cupsfilter.so`      |
| filter gziptoany     | `lib/cups/filter/gziptoany`        | `libcupsf_gziptoany.so`       |
| filter pstops        | `lib/cups/filter/pstops`           | `libcupsf_pstops.so`          |
| filter commandtops   | `lib/cups/filter/commandtops`      | `libcupsf_commandtops.so`     |
| filter rastertopwg   | `lib/cups/filter/rastertopwg`      | `libcupsf_rastertopwg.so`     |
| filter rastertoepson | `lib/cups/filter/rastertoepson`    | `libcupsf_rastertoepson.so`   |
| filter rastertohp    | `lib/cups/filter/rastertohp`       | `libcupsf_rastertohp.so`      |
| filter rastertolabel | `lib/cups/filter/rastertolabel`    | `libcupsf_rastertolabel.so`   |
| filter imagetoraster | `out/arm64-cupsfilters/filter/imagetoraster` | `libcupsf_imagetoraster.so` |
| client lpstat        | `bin/lpstat`                       | `libcupstool_lpstat.so`       |
| client lpadmin       | `bin/lpadmin`                      | `libcupstool_lpadmin.so`      |
| client lp            | `bin/lp`                           | `libcupstool_lp.so`           |
| cgi admin            | `lib/cups/cgi-bin/admin.cgi`       | `libcupscgi_admin.so`         |
| cgi printers         | `lib/cups/cgi-bin/printers.cgi`    | `libcupscgi_printers.so`      |
| cgi jobs             | `lib/cups/cgi-bin/jobs.cgi`        | `libcupscgi_jobs.so`          |
| cgi classes          | `lib/cups/cgi-bin/classes.cgi`     | `libcupscgi_classes.so`       |
| cgi help             | `lib/cups/cgi-bin/help.cgi`        | `libcupscgi_help.so`          |
| NDK C++ runtime      | NDK sysroot `libc++_shared.so`     | `libc++_shared.so`            |

## Gutenprint DNP dye-sub add-ons (source tree: `tool/android/out/arm64-gutenprint/`)

These come from the Gutenprint cross-build (see `gutenprint/NOTES.md`), NOT the
CUPS build. They are GPL binaries, kept as separately-exec'd processes (the
license firewall — never linked into the MIT plugin). All are self-contained PIE
executables (libgutenprint + libusb statically embedded) except genppd (needs
libz, present on device).

| Gutenprint role         | source (out/arm64-gutenprint/...)          | jniLibs name                        |
|-------------------------|--------------------------------------------|-------------------------------------|
| dye-sub USB backend     | `cups/backend/gutenprint53+usb`            | `libcupsbe_gutenprint53usb.so`      |
| raster filter           | `cups/filter/rastertogutenprint.5.3`       | `libcupsf_rastertogutenprint.so`    |
| dye-sub command filter  | `cups/filter/commandtodyesub`              | `libcupsf_commandtodyesub.so`       |
| PPD generator (runtime) | `bin/cups-genppd.5.3`                       | `libcupstool_gutenprint_genppd.so`  |

The backend's canonical (install) name is `gutenprint53+usb` — the `+` is illegal
in a `lib*.so` filename, so it's stored as `libcupsbe_gutenprint53usb.so` and the
symlink farm links `serverbin/backend/gutenprint53+usb` -> that .so.

The gutenprint driver DATA (`share/gutenprint/5.3/xml/`, ~6.6 MB, 340 files) is
NOT a jniLib — it is shipped as APK **assets** under
`example/android/app/src/main/assets/gutenprint/share/gutenprint/...` and
extracted by MainActivity.extractGutenprintData(). The filter/backend/genppd
find it via the `STP_DATA_PATH` env var (set to the extracted
`.../share/gutenprint/5.3/xml` dir), which cupsd passes to its children.

`libc++_shared.so` is included because `cups-driverd` is the one binary with a
non-bionic dependency (it links the C++ ppdc library). Every other binary needs
only bionic libs (`libc`, `libm`, `libdl`, `libz`). AGP normally bundles
`libc++_shared.so` automatically (the app already has C++ via the CMake
externalNativeBuild), but it is staged explicitly here to guarantee the loader
resolves `cups-driverd`.

## Image -> CUPS-raster input filter (source tree: `tool/android/out/arm64-cupsfilters/`)

`imagetoraster` comes from **cups-filters 1.28.17** (built by
`tool/android/build-cupsfilters.sh`), NOT the CUPS core build. CUPS 2.x moved the
input filters out of core into the separate cups-filters project, so without this
cupsd rejects "unsupported document format image/jpeg". It converts
image/jpeg | image/png | image/gif | image/bmp | ... -> application/vnd.cups-raster,
which the DNP PPD then feeds to `rastertogutenprint.5.3` -> `gutenprint53+usb`.

| role                    | source (out/arm64-cupsfilters/...)   | jniLibs name                    |
|-------------------------|--------------------------------------|---------------------------------|
| image -> raster filter  | `filter/imagetoraster`               | `libcupsf_imagetoraster.so`     |

It is a self-contained AArch64 PIE (bionic-only NEEDED: libc/libm/libdl/libz).
The permissive image libs (libjpeg-turbo 3.0.4 BSD/IJG, libpng 1.6.44) are
STATICALLY embedded — built by `tool/android/build-imagelibs.sh` into
`tool/android/out/arm64-imagelibs/` (also builds libtiff 4.6.0, currently NOT
linked). NO PDF renderer (ghostscript/poppler/mutool/qpdf) and NO AGPL is bundled;
imagetoraster is exec'd by cupsd as a separate process (license firewall).

The mime CONV rules ship as an APK asset:
`example/android/app/src/main/assets/cups/share/cups/mime/imagetoraster.convs`
(extracted by MainActivity.extractCupsData alongside mime.types/mime.convs). The
symlink farm links `serverbin/filter/imagetoraster` -> the .so above.

## Naming convention

- `libcupsd.so`          — the scheduler (the one "d" suffix = the daemon `cupsd`)
- `libcupsbe_<name>.so`  — a CUPS **be**ckend
- `libcupsd_<name>.so`   — a cups**d** helper daemon (cups-<name>)
- `libcupsf_<name>.so`   — a CUPS **f**ilter
- `libcupstool_<name>.so`— a CUPS client **tool**
- `libcupscgi_<name>.so` — a CUPS web-interface **cgi** program (name = the .cgi stem)

## Runtime symlink farm (built by the app — SEPARATE later task)

cupsd discovers backends/filters/daemons by their canonical names under
`ServerBin` (e.g. `serverbin/backend/socket`, `serverbin/filter/gziptoany`,
`serverbin/daemon/cups-driverd`). At boot the app should build a symlink farm in
its writable dir that points each canonical name at the corresponding extracted
`lib*.so` in `nativeLibraryDir`, e.g.:

```
<serverbin>/backend/socket        -> <nativeLibraryDir>/libcupsbe_socket.so
<serverbin>/backend/ipp           -> <nativeLibraryDir>/libcupsbe_ipp.so
<serverbin>/backend/lpd           -> <nativeLibraryDir>/libcupsbe_lpd.so
<serverbin>/backend/snmp          -> <nativeLibraryDir>/libcupsbe_snmp.so
<serverbin>/backend/usb           -> <nativeLibraryDir>/libcupsbe_usb.so
<serverbin>/backend/http          -> <nativeLibraryDir>/libcupsbe_http.so
<serverbin>/daemon/cups-deviced   -> <nativeLibraryDir>/libcupsd_deviced.so
<serverbin>/daemon/cups-driverd   -> <nativeLibraryDir>/libcupsd_driverd.so
<serverbin>/daemon/cups-exec      -> <nativeLibraryDir>/libcupsd_exec.so
<serverbin>/daemon/cups-lpd       -> <nativeLibraryDir>/libcupsd_lpd.so
<serverbin>/daemon/cupsfilter     -> <nativeLibraryDir>/libcupsd_cupsfilter.so
<serverbin>/filter/gziptoany      -> <nativeLibraryDir>/libcupsf_gziptoany.so
<serverbin>/filter/pstops         -> <nativeLibraryDir>/libcupsf_pstops.so
<serverbin>/filter/commandtops    -> <nativeLibraryDir>/libcupsf_commandtops.so
<serverbin>/filter/rastertopwg    -> <nativeLibraryDir>/libcupsf_rastertopwg.so
<serverbin>/filter/rastertoepson  -> <nativeLibraryDir>/libcupsf_rastertoepson.so
<serverbin>/filter/rastertohp     -> <nativeLibraryDir>/libcupsf_rastertohp.so
<serverbin>/filter/rastertolabel  -> <nativeLibraryDir>/libcupsf_rastertolabel.so
<serverbin>/filter/imagetoraster  -> <nativeLibraryDir>/libcupsf_imagetoraster.so
<serverbin>/cgi-bin/admin.cgi     -> <nativeLibraryDir>/libcupscgi_admin.so
<serverbin>/cgi-bin/printers.cgi  -> <nativeLibraryDir>/libcupscgi_printers.so
<serverbin>/cgi-bin/jobs.cgi      -> <nativeLibraryDir>/libcupscgi_jobs.so
<serverbin>/cgi-bin/classes.cgi   -> <nativeLibraryDir>/libcupscgi_classes.so
<serverbin>/cgi-bin/help.cgi      -> <nativeLibraryDir>/libcupscgi_help.so
```
cupsd itself is launched directly as `<nativeLibraryDir>/libcupsd.so`.

The web interface (`WebInterface Yes`) also needs (extracted from app assets, not
jniLibs): `<DataDir>/templates/*.tmpl` — the CGI HTML templates (cupsd sets
`CUPS_DATADIR=<DataDir>`; `cgiGetTemplateDir()` reads `$CUPS_DATADIR/templates`)
and a `DocumentRoot` (static index.html/cups.css/images/help) set in
`cups-files.conf` and served by cupsd for `/`, `/cups.css`, `/images/...`.

NOTE: cupsd checks that backends/filters are NOT group/world-writable. Files in
`nativeLibraryDir` are owned by the app uid and not writable, so this passes.
Symlinks themselves are fine (cupsd stats the target).
