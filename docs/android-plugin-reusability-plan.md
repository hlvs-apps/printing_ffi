# Plan: make the printing_ffi Android/CUPS port fully reusable

**Status:** locked via `/plan-eng-review` on 2026-07-04. Branch `hlvs-apps/android-cups-usb-proxy`.
**Goal:** a Flutter app that already uses `printing_ffi` on desktop adds the Android
target (CUPS printing + DNP USB dye-sub auto-detect) with **build-config changes only**,
the same bar as the `flutter_fotobox_gphoto` Android migration guide. Today all the glue
lives in `example/`; it must move into the plugin.

---

## Locked decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Native lib distribution | **Build CUPS+gutenprint+libusb from source during the app's Gradle build** (no binaries in git) | The prebuilt jniLibs in `example/` were a spike shortcut. gphoto model was always the intent. |
| D2 | Settings WebView dep | **In the core plugin** (`webview_flutter`) | One dependency for the app; `webview_flutter` native side isn't built on desktop, ~zero cost there. |
| D3 | cupsd boot | **One explicit call** `await PrintingFfi.instance.initializeAndroidCups()` at startup (no-op off Android) | Explicit > clever; keeps control of ANR-sensitive USB-scan timing. |
| D4 | Build scripts | **Thin `android/build_cups_android.sh` orchestrator that reuses the existing `tool/android/*.sh`** | DRY, reuses tested scripts, smallest diff. |
| D5 | Windows host | **WSL2** (detect non-POSIX host, print "build under WSL2") | WSL2 *is* a Linux host, so the same script path works with zero Windows-specific code. Native MSYS2/CMake-rewrite are oceans. |

---

## Success criteria (the gphoto bar, concretely)

A consumer app that already uses `printing_ffi` on desktop does **only** this to get Android:

1. `pubspec.yaml` — same dependency, no change.
2. `android/app/build.gradle(.kts)` — arm64 ABI filter + `useLegacyPackaging = true` (cupsd must exec on-disk PIE libs) + `ndkVersion` pin.
3. `AndroidManifest.xml` — the ~8-line USB-attach `<intent-filter>` + `<meta-data>` pointing at the plugin-shipped `@xml/printing_ffi_usb_device_filter` (must sit on the app's launcher Activity — plugins can't host a launcher).
4. Dart — **one** line at startup: `await PrintingFfi.instance.initializeAndroidCups();`
5. Settings UI — call `PrintingFfi.instance.openCupsSettings(context)` / `openCupsPrinterSettings(context, printerName)`. No app-built widgets.

Everything else (native cross-compile, asset extraction, USB permission, fd handoff, DNP
auto-add, FGS, the WebView) is inside the plugin.

---

## Target architecture

```
                       printing_ffi plugin (self-contained)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │ pubspec.yaml: plugin.platforms.android { ffiPlugin: true,                   │
 │               package: dev.<...>.printing_ffi, pluginClass: PrintingFfiPlugin}│
 │                                                                             │
 │ android/                                                                    │
 │   build.gradle .......... com.android.library + kotlin-android;             │
 │                           cupsAbis(default arm64-v8a); wires STAGE/JNILIBS/  │
 │                           ASSETS/CACHE dirs; sourceSets.main.jniLibs.srcDirs │
 │                           += cupsJniLibs; .assets.srcDirs += cupsAssets;     │
 │                           externalNativeBuild -> android/CMakeLists.txt       │
 │   CMakeLists.txt ........ execute_process(build_cups_android.sh) at CONFIGURE│
 │                           (guarantees libs exist before link); then          │
 │                           add_library(printing_ffi ../src/printing_ffi.c);   │
 │                           link staged libcups; -Wl,-z,max-page-size=16384    │
 │   build_cups_android.sh . idempotent+cached orchestrator (env contract);     │
 │                           calls tool/android/*.sh; flattens sonames; stages   │
 │                           runtime .so -> JNILIBS, share/* -> ASSETS, libcups  │
 │                           + headers -> STAGE                                 │
 │   src/main/kotlin/PrintingFfiPlugin.kt  (FlutterPlugin + ActivityAware)      │
 │   src/main/res/xml/printing_ffi_usb_device_filter.xml                        │
 │   src/main/AndroidManifest.xml  (FGS service, perms, extractNativeLibs=true) │
 │                                                                             │
 │ lib/                                                                        │
 │   printing_ffi.dart ..... + initializeAndroidCups(), cupsServerPort,         │
 │                           openCupsSettings(), openCupsPrinterSettings()       │
 │   src/cups_android.dart . boot facade (was example CupsAndroidBoot)          │
 │   src/dnp_usb.dart ...... DNP auto-detect (was example DnpUsb)               │
 │   src/cups_web_view.dart  CupsWebView widget + the open* impl                │
 │                                                                             │
 │ src/printing_ffi.c/.h ... UNCHANGED (shared across all platforms)           │
 │ tool/android/*.sh ....... reused by the orchestrator (dev tooling stays)     │
 └───────────────────────────────────────────────────────────────────────────┘

 Build-time flow (per `flutter build apk`, arm64):
   Gradle configure ─▶ android/CMakeLists.txt ─▶ execute_process
        ─▶ build_cups_android.sh (cache HIT → instant; MISS → cross-compile)
             ├─ tool/android/build-libusb.sh      ─┐
             ├─ tool/android/build-imagelibs.sh     │ into CACHE_DIR/prefix/arm64
             ├─ tool/android/build-cups.sh          │  (~/.gradle/printing-ffi-cups-cache)
             ├─ tool/android/build-cupsfilters.sh   │
             ├─ tool/android/build-gutenprint.sh   ─┘
             ├─ flatten sonames (patchelf) + strip
             ├─ runtime .so   ─▶ JNILIBS_DIR  (packaged via jniLibs.srcDirs)
             ├─ share/cups + share/gutenprint ─▶ ASSETS_DIR (packaged via assets.srcDirs)
             └─ libcups(.a) + headers ─▶ STAGE_DIR (linked into libprinting_ffi.so)
        ─▶ CMake links printing_ffi.c + staged libcups ─▶ libprinting_ffi.so

 Runtime flow (unchanged mechanics, now owned by the plugin):
   app: await initializeAndroidCups()
        └─ getCupsPaths (extract assets, idempotent) ─▶ startCupsServer() ─▶ port stored
           └─ DnpUsb.start(): watch USB, deferred initial scan (1.5s, ANR-safe)
   plug DNP ─▶ Android matches plugin @xml ─▶ launches app
           ─▶ PrintingFfiPlugin(ActivityAware).onNewIntent ─▶ UsbManager.requestPermission
           ─▶ fd ─▶ startUsbFdServer(fd) ─▶ generateDnpPpd(make) ─▶ addCupsPrinter ─▶ print
   openCupsSettings(ctx) ─▶ Navigator.push(CupsWebView('http://127.0.0.1:$port/admin'))
```

---

## The build system (the crux) — mirrors gphoto exactly

### `android/build.gradle`
Add `apply plugin: "kotlin-android"`. Then, per the gphoto reference:

```groovy
def cupsAbis   = (project.findProperty("cupsAbis") ?: "arm64-v8a").split(",").collect { it.trim() }
def cupsRoot   = "${buildDir}/cups"
def cupsStage  = "${cupsRoot}/stage"      // per-ABI include/ + lib/ for CMake link
def cupsJniLibs= "${cupsRoot}/jniLibs"    // per-ABI runtime .so packaged into APK
def cupsAssets = "${cupsRoot}/assets"     // share/cups + share/gutenprint packaged into APK
def cupsCache  = "${project.gradle.gradleUserHomeDir}/printing-ffi-cups-cache"

android {
  ndkVersion = "27.0.12077973"            // pin; 16KB-aligned by default
  defaultConfig {
    minSdk = 24
    ndk { abiFilters(*cupsAbis.toArray(new String[0])) }   // CUPS only builds arm64 today
    externalNativeBuild { cmake { arguments
      "-DCUPS_STAGE=${cupsStage}", "-DCUPS_JNILIBS=${cupsJniLibs}",
      "-DCUPS_ASSETS=${cupsAssets}", "-DCUPS_CACHE=${cupsCache}" } }
  }
  externalNativeBuild { cmake { path = "CMakeLists.txt"; version = "3.22.1" } }
  sourceSets {
    main.jniLibs.srcDirs += cupsJniLibs
    main.assets.srcDirs  += cupsAssets    // <-- CUPS also ships DATA assets (gphoto doesn't)
  }
  defaultConfig { consumerProguardFiles "consumer-rules.pro" }
}
```

### `android/CMakeLists.txt` (new)
- `execute_process` runs `build_cups_android.sh` with the env contract, at configure time.
- Fail loudly if the stage dir is missing after.
- `add_library(printing_ffi SHARED ../src/printing_ffi.c)`, include `${STAGE}/include`,
  link `${STAGE}/lib/libcups.a` (+ `libcupsimage.a`, `z m dl log`) by absolute path
  (NDK re-roots `find_library`, so use explicit paths — same lesson as gphoto).
- `-Wl,-z,max-page-size=16384`.
- Point `android/build.gradle` at this file; the Android branch in `src/CMakeLists.txt`
  becomes dead → strip it (desktop/Windows branches stay). **Delete the committed
  `tool/android/out/` link target** (now a build artifact).

### `android/build_cups_android.sh` (new, thin orchestrator)
Env contract (mirrors gphoto): `ABI MIN_SDK NDK STAGE_DIR JNILIBS_DIR ASSETS_DIR CACHE_DIR`.
Steps:
1. **Host detect** — `uname -s`: `Darwin`/`Linux` → proceed. `MINGW*/MSYS*/CYGWIN*` or unset
   → `echo "printing_ffi: build the Android target under WSL2 (autotools+patchelf needed)"; exit 1`.
2. **Preflight tools** — `autoconf automake libtool make pkg-config bash curl tar patchelf`
   with macOS/Ubuntu install hints (add a WSL2 line). Fail fast, clear message.
3. **Cache marker** — key = pinned versions of cups/gutenprint/libusb/cupsfilters/imagelibs.
   `.built-$KEY` in STAGE_DIR, only trusted if `libcups.a` + the runtime `.so` are actually
   present. HIT → exit 0 (instant). Persist under `~/.gradle/...` (survives `flutter clean`).
4. **Cross-compile** into `CACHE_DIR/prefix/$ABI` by calling the existing scripts in order:
   `build-libusb.sh → build-imagelibs.sh → build-cups.sh → build-cupsfilters.sh →
   build-gutenprint.sh`. (Refactor those to accept the env contract instead of hard-coded
   paths — they already take `CUPS_LINK` etc.; parameterize `PREFIX`/`NDK`/`ABI`/`MIN_SDK`.)
5. **Flatten + strip** sonames (`patchelf`, Android needs flat unversioned `lib*.so`), same
   as `stage.sh` does today; drop the runtime `.so` set into `JNILIBS_DIR` (the 34 libs:
   cupsd, backends `libcupsbe_*`, filters, cgi `libcupscgi_*`, gutenprint backend, libusb,
   `libc++_shared`).
6. **Stage assets** into `ASSETS_DIR/cups/share/{cups,doc}` + `gutenprint/share/gutenprint`
   using the **corrected** template staging (the locale-flatten fix already landed in
   `stage.sh:125` — carry it into the orchestrator so the "web UI is Russian" bug can't recur).
7. **Stage link inputs** — `libcups.a`/`libcupsimage.a` + headers → `STAGE_DIR/{lib,include}`.
8. Write `manifest.txt`; write cache marker.

> The heavy lifting already exists in `tool/android/*.sh`. This orchestrator adds: the env
> contract, host/WSL2 detection, the cache marker, and the assets staging into a build dir
> (instead of the manual `out/ → example assets` copy that exists today).

---

## Kotlin: `PrintingFfiPlugin.kt` (FlutterPlugin + ActivityAware)

Consolidates today's `MainActivity` method-channel handler + `DnpUsbManager` +
`DnpUsbForegroundService`. Channels keep their current names so the Dart side barely changes:
`printing_ffi/cups` (MethodChannel), `printing_ffi/usb` (MethodChannel),
`printing_ffi/usb_events` (EventChannel).

```
onAttachedToEngine(binding):
    applicationContext = binding.applicationContext
    register cups + usb MethodChannels, usb_events EventChannel
    // getCupsPaths, scan, requestDevice, closeDevice, start/stopForegroundService handlers

onAttachedToActivity(binding):
    activity = binding.activity
    binding.addOnNewIntentListener { intent -> usb.handleAttachIntent(intent) }  // auto-open on plug
    also handle the *initial* launch intent (cold start from USB_DEVICE_ATTACHED)
    register the USB-permission BroadcastReceiver (needs a Context)
onDetachedFromActivity(): drop activity ref, unregister receiver

getCupsPaths: the asset-extraction currently in MainActivity (extractIfStale +
    copyAssetDir with the world-readable fix already landed) — unchanged logic.
```

`DnpUsbForegroundService` moves verbatim into the plugin package. `usb.host` availability is
checked at runtime; absent → clean error (don't hard-require the feature at manifest level so
non-USB devices still install).

**Consumer MainActivity becomes the default `FlutterActivity`** — zero custom Kotlin. The
attach `<intent-filter>` on it is the only app-side manifest addition; the plugin's
`ActivityAware.onNewIntent` picks up the plug event.

---

## Manifest split

**Plugin `android/src/main/AndroidManifest.xml`** (merges into every consumer):
```xml
<uses-feature android:name="android.hardware.usb.host" android:required="false"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<application android:extractNativeLibs="true">   <!-- cupsd must exec on-disk PIE libs -->
  <service android:name=".DnpUsbForegroundService" android:exported="false"
           android:foregroundServiceType="connectedDevice"/>
</application>
```
**Documented consumer caveat (like gphoto):** an app that sets
`android:extractNativeLibs="false"` hits a merge conflict and must add
`tools:replace="android:extractNativeLibs"`. Also `packaging { jniLibs { useLegacyPackaging = true } }`
in the app's gradle (AGP default is false, which mmaps libs and leaves nothing to exec).

**App manifest** keeps only: the USB-attach `<intent-filter>` + `<meta-data
@xml/printing_ffi_usb_device_filter>` on the launcher Activity.

---

## Dart API (plugin `lib/`)

Already landed this session: `cupsServerPort`, `cupsBaseUrl`, `cupsSettingsUrl`,
`cupsPrinterSettingsUrl(name)` on `PrintingFfi` (port captured in `startCupsServer`).

To add:
- `Future<void> initializeAndroidCups()` — no-op off Android; else runs the boot facade
  (`getCupsPaths` → `startCupsServer` → `DnpUsb.start()`), idempotent. Exposes
  `ValueNotifier<String> cupsStatus` and `ValueNotifier<List<DnpUsbPrinter>> dnpPrinters`.
- `Future<void> openCupsSettings(BuildContext, {String? title})` → push `CupsWebView(cupsSettingsUrl)`.
- `Future<void> openCupsPrinterSettings(BuildContext, {required String printerName, String? title})`
  → push `CupsWebView(cupsPrinterSettingsUrl(name))`. Both toast/return cleanly if
  `cupsServerPort == null` (not booted).
- `CupsWebView` widget (moved from `example/lib/cups_web_properties_page.dart`, generalized;
  keeps the device-locale behavior fix). Plugin gains `webview_flutter` dependency.
- Move `CupsAndroidBoot` → `lib/src/cups_android.dart`, `DnpUsb`/`DnpUsbPrinter` →
  `lib/src/dnp_usb.dart`. Add `shared_preferences` dep (DNP persistence).

---

## Example app after refactor (the proof / "using app")

- Delete `example/.../jniLibs/`, `example/.../assets/`, `example/.../cpp/` (dead spike),
  `MainActivity.kt` custom code (→ default `FlutterActivity`), `DnpUsbManager.kt`,
  `DnpUsbForegroundService.kt`, `res/xml/usb_device_filter.xml`, `cups_android_boot.dart`,
  `dnp_usb.dart`, `cups_web_properties_page.dart`.
- Keep: `build.gradle.kts` (arm64 + `useLegacyPackaging`), the manifest attach filter (now
  → plugin `@xml`), and Dart that calls `initializeAndroidCups()` + the `open*` functions.
- The example's net Android footprint should shrink to the same 5 things a real consumer adds.

---

## Sequencing (each stage independently verifiable; example must keep printing)

1. **Dart API surface (done/in-progress, zero risk):** port getter + URL helpers (landed),
   `CupsWebView` + `open*` + `initializeAndroidCups` as a thin facade that still calls the
   example's existing boot for now. Ship + on-device check the two settings pages.
2. **Build-from-source wiring:** add `android/CMakeLists.txt` + `build_cups_android.sh` +
   build.gradle stage/jnilibs/assets wiring; parameterize `tool/android/*.sh`. Verify the
   plugin's own `libprinting_ffi.so` + the runtime `.so` + assets are produced into build
   dirs and the **example still builds and prints** with its committed jniLibs/assets
   removed. This is the highest-risk stage — gate hard on-device.
3. **Kotlin move:** author `PrintingFfiPlugin` (ActivityAware) + move FGS; add `pluginClass`
   to pubspec; move `@xml` + manifest bits into the plugin. Slim the example MainActivity +
   manifest. Verify DNP auto-add + FGS + settings on-device.
4. **Dart move:** relocate `CupsAndroidBoot`/`DnpUsb` into the plugin; example calls only the
   public API. Final on-device acceptance run.
5. **Docs + gitignore:** consumer migration guide (gphoto-style), `.gitignore` covering all
   generated artifacts, delete `tool/android/out` commit. Publish-readiness note.

Stages 2–4 are the meat; keep each behind a green on-device run before the next.

---

## Failure modes

| Codepath | Realistic failure | Test? | Handled? | User sees |
|----------|-------------------|-------|----------|-----------|
| `build_cups_android.sh` on Windows host | autotools/patchelf absent | preflight | yes | clear "use WSL2" message, build stops |
| Cache marker stale after version bump | links old libcups | marker keyed on versions | yes | rebuild triggered |
| `sourceSets.assets.srcDirs` not packaged | web UI + PPDs 404 at runtime | on-device | partial | **CRITICAL gap** — add acceptance check |
| `extractNativeLibs=false` in consumer | cupsd can't exec → boot fails | — | doc caveat only | boot error in log |
| ActivityAware not attached (headless) | USB permission null-Activity crash | Robolectric | must guard | clean error, no crash |
| PPD path relative (known TODO) | addCupsPrinter fails for non-DS620 | on-device | verify | printer add fails |
| WebView before cupsd booted | `cupsServerPort==null` | Dart unit | yes | toast "server not started" |

---

## Test plan

**Dart unit (pure, cheap — add all):**
- `cupsBaseUrl`/`cupsSettingsUrl`/`cupsPrinterSettingsUrl` incl. name encoding + null-port.
- `DnpUsb._deriveQueueName` / `_deviceUri` / `_sanitize` (regex edge cases: empty serial,
  slashes, unicode).
- `initializeAndroidCups` idempotency + off-Android no-op (platform override).

**Kotlin (Robolectric, mirror gphoto's `UsbPluginTest`):**
- device-filter VID/PID matching; asset-extraction idempotency (`extractIfStale`);
  channel handler argument parsing; ActivityAware attach/detach guards.

**On-device acceptance gate (the real one — run on the S25 each stage 2–4):**
1. cold start → `initializeAndroidCups()` → cupsd up, `listPrinters()` works.
2. plug DNP DS-RX1 → auto-add → queue appears.
3. print a photo → job completes (FGS notification visible).
4. `openCupsPrinterSettings` → German (device-locale) UI, **CSS loads**.
5. `openCupsSettings` → `/admin` renders.
6. unplug → queue removed, fd-server stopped.
7. **cold build validation:** `flutter clean` + wipe `~/.gradle/printing-ffi-cups-cache`
   → full from-source build → still prints. Then second build → cache HIT, fast.

Artifact for `/qa`: written to `~/.gstack/projects/.../eng-review-test-plan-*.md`.

---

## NOT in scope (deferred, with rationale)

- **pub.dev publishing** — 64MB generated + git-dependency model targets `git:` deps like
  gphoto; pub.dev size limits are a separate effort.
- **Non-arm64 ABIs** (x86_64 emulator, armeabi-v7a) — CUPS cross-build is arm64-only today;
  `-PcupsAbis` hook is left in place for later.
- **Native Windows without WSL2** — autotools limitation, would require rewriting CUPS's
  build in CMake (ocean). WSL2 is the supported Windows path.
- **iOS** — no cupsd-exec / USB-host path.
- **Inkjet/AGPL drivers** — out by design (see licensing).

## What already exists (reuse, do not rebuild)

- `src/printing_ffi.c/.h` FFI primitives (`startCupsServer`, `addCupsPrinter`,
  `startUsbFdServer`, `generateDnpPpd`, …) — unchanged.
- `tool/android/*.sh` cross-compile scripts — reused by the orchestrator (D4).
- `example/` orchestration (`CupsAndroidBoot`, `DnpUsb`, `DnpUsbManager`,
  `DnpUsbForegroundService`, `usb_device_filter.xml`, WebView page) — **relocated**, not
  rewritten. It prints today; the refactor preserves behavior.
- `stage.sh` corrected template staging + the world-readable docroot fix (landed this
  session) — carried into the orchestrator.

## Parallelization

Mostly sequential (stages 2→3→4 share the Android module and gate on the same on-device
run). One safe parallel lane:
- **Lane A:** stages 2–4 (native build → Kotlin → Dart move), sequential, shared `android/`.
- **Lane B (parallel):** Dart unit tests + the consumer migration guide + `.gitignore` —
  independent of the native module, can be authored alongside Lane A.

Conflict flag: Lane A stage 4 and Lane B both touch `lib/` — land Lane A's `lib/` move first,
then rebase the tests.

---

## Outside-voice corrections folded in (codex, 2026-07-04)

An independent codex review caught real gaps. These are now **requirements**, not
nice-to-haves:

**Build system (the "thin orchestrator" is thinner in prose than in reality):**
- **C1. De-hardcode the scripts.** `tool/android/*.sh` currently hard-code the NDK path,
  `darwin-x86_64`, `sysctl -n hw.ncpu`, and `tool/android/out`. Real work to make them take
  `NDK/ABI/MIN_SDK/HOST_TAG/JOBS/PREFIX` from the env contract. Not a light touch.
- **C2. All writes leave the plugin checkout.** A git-dependency plugin lives in a
  **read-only** pub-cache dir; consumer builds must not write into it. Downloads, build tree,
  `out/`, and cache all go under `~/.gradle/printing-ffi-cups-cache` (never `tool/android/`).
  Prevents worktree collisions + read-only-cache failures.
- **C3. Pin + checksum every source** (CUPS, gutenprint, libusb, libpng/jpeg/tiff,
  cupsfilters) with SHA256, exactly like gphoto's script does. Gives reproducibility; the
  checksum set is part of the cache key. (Downloads-during-build remains — see the T1 tension.)
- **C4. Assets ordering is the real risk.** `sourceSets.assets.srcDirs` pointing at a
  CMake-configure-generated dir may snapshot before CMake runs. Mitigation: prove it in
  stage 2; if it races, wire an explicit Gradle `Exec` task with declared `inputs/outputs`
  that `mergeAssets`/`mergeJniLibFolders` depend on. gphoto only does this for jniLibs (proven);
  **assets is the untested delta.**
- **C5. 16 KB alignment on every shipped binary**, not just `libprinting_ffi.so` — the
  cross-build must pass `-Wl,-z,max-page-size=16384` to every CUPS/gutenprint/helper link.
- **C6. Symlink-farm names must match exactly.** `printing_ffi.c` builds a symlink farm to
  specific `lib*.so` names (cupsd/backends/filters/cgi). The from-source output must produce
  those exact names — verify against the farm, not just "34 libs".
- **C7. CMake 3.22.1 pin is a consumer requirement.** The current `android/build.gradle`
  comment says don't raise CMake past what Flutter needs (3.10+); the source-build needs
  3.22.1. Document it as a hard floor.

**Kotlin / Android:**
- **C8. USB permission action must be app-scoped.** Today it's the hard-coded
  `com.example.printing_ffi_example.USB_PERMISSION`. In a reusable plugin, derive it from
  `context.packageName` (e.g. `"$packageName.PRINTING_FFI_USB_PERMISSION"`) so two apps can't
  collide.
- **C9. `launchMode="singleTop"` is a consumer requirement.** Hotplug re-entry relies on
  `onNewIntent`; a bare `FlutterActivity` without `singleTop` spawns a new activity instead.
  Add it to the "5 things the consumer adds".
- **C10. POST_NOTIFICATIONS runtime grant (Android 13+).** The FGS notification needs a
  runtime request or a defined degraded path; declaring the permission isn't enough.
- **C11. ActivityAware lifecycle must not kill an active print.**
  `onDetachedFromActivityForConfigChanges` (rotation/backgrounding) must **not** run
  `DnpUsbManager.unregister()` (which closes USB + shuts the executor). Only tear down on real
  detach. The FGS is what keeps a job alive across backgrounding.
- **C12. Namespace/package migration is a real subtask.** `com.example.printing_ffi(_example)`
  → a real `dev.<...>` package: manifest names, service name, permission action, resources,
  ProGuard/`consumer-rules.pro`, and the generated plugin registrant all move together.

**Dart API:**
- **C13. Define lifecycle/concurrency, not just "idempotent".** Specify `ValueNotifier`
  state after `stopCupsServer`, hot restart, activity recreation, failed boot, detach-during-boot,
  and concurrent `initializeAndroidCups()` calls (single-flight the boot).
- **C14. Name the ANR risk honestly.** `startCupsServer`/`addCupsPrinter`/`generateDnpPpd`
  are synchronous FFI pinned to the UI isolate (libcups keeps target-server state thread-local).
  `Future<void>` does not make them non-blocking. Document the constraint + the deferral tricks
  that keep them off the focus window.

**Tests / licensing:**
- **C15. Robolectric is for parsing/matching only.** USB host, `getFileDescriptor()`, FGS,
  and generated-asset extraction need on-device/instrumentation — the on-device gate is the
  real coverage, Robolectric won't substitute.
- **C16. License compliance is an acceptance criterion, not a deferred doc.** Gutenprint
  GPL executables are bundled + exec'd; the consumer artifact (and generated assets) must carry
  the license notices / written-offer. Verify in the acceptance gate. (See existing `LICENSING.md`.)

**Not changed (codex flagged, decision stands):** webview_flutter in core (D2) — codex prefers
a separate `printing_ffi_android_ui` package for transitive-dep hygiene; you chose core. Noted
as a caveat, not reopened.

## Open risks to watch

1. **Assets via `sourceSets.assets.srcDirs`** — verify generated assets actually land in the
   APK's `assets/` and that `AssetManager.list("cups/...")` still resolves post-merge. First
   thing to prove in stage 2.
2. **Hybrid plugin registration** — `ffiPlugin: true` + `pluginClass` together; confirm the
   Flutter tool generates the registrant and the FFI `DynamicLibrary.open('libprinting_ffi.so')`
   still resolves.
3. **First-build time** — full CUPS+gutenprint cross-compile is minutes; cache must survive
   `flutter clean`. CI must cache `~/.gradle`.
4. **PPD absolute-path TODO** — pre-existing; validate during stage 3 on-device.

---

## Cross-model resolution (T1)

Codex challenged D1 (source-build on every consumer needs network + autotools). **Resolved:
keep pure from-source** (matches gphoto exactly), **SHA256-pin all sources** (C3) for
reproducibility. Air-gapped *first* build is explicitly unsupported (documented); cached
forever after. A CI-prebuilt-download path is a future enhancement, not this scope.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | issues_found | 20 findings; 16 folded (C1–C16), 1 tension resolved (T1), 1 caveat (D2) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open | 5 decisions locked, 1 impl-time gap (assets ordering, C4) |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **CODEX:** 20 findings; the real ones (read-only cache C2, USB-permission collision C8,
  singleTop C9, assets ordering C4, license acceptance C16) folded into the plan.
- **CROSS-MODEL:** T1 resolved (keep from-source + SHA256 pin). D2 (webview in core) held.
- **UNRESOLVED:** 0 decisions. One impl-time verification gap (C4 assets ordering) to prove in Stage 2.
- **VERDICT:** ENG + CODEX reviewed — plan locked, ready to implement Stage 1.
