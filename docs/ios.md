# Optional bundled CUPS on iOS

The iOS device build bundles CUPS 2.4.19, Gutenprint 5.3.5, libusb 1.0.27,
and the JPEG/PNG raster filters. No separately installed CUPS service is used.
The supported DNP/Citizen models match the Android model list, including
DS-RX1/RX1HS and DS620. The detected model selects its own PPD; there is no raw
queue or different-model fallback.

Call `CupsIos.instance.watch()` after the first frame on the main Flutter engine.
Observe `CupsIos.instance.ready`, `queueName`, and `status`. Use `PrintingFfi`
only after readiness. The app must continue normally when readiness is false.
The native boot work runs on a serial background queue. While foregrounded,
discovery and scheduler health are checked every five seconds; they are checked
on resume as well. An existing scheduler is reused. USB discovery is deferred
while CUPS has active jobs, so it does not claim an interface that may be printing. A disconnected printer's queued jobs remain
in CUPS for reconnection, as on Android.

## Access, independent of jailbreak name

Before starting CUPS, the plugin executes the bundled Gutenprint backend in
discovery mode. That backend opens and claims a supported USB interface before
reporting its device URI. Failure to launch, denied USB access, no supported
printer, or timeout leaves CUPS stopped. There are no jailbreak-brand, OS-version,
or marker-file checks. A jailbreak alone does not promise the app has the needed
permissions: its installation/signing environment must permit this app to spawn
its bundled executables and permit the backend's IOKit USB access.

The USB library is linked into a separate helper, not the app framework. Stock
iOS can load the app without loading private USB code; a denied helper launch
is returned as unavailable printing.

**The process that hosts this runtime must run unsandboxed.** iOS denies a
sandboxed container app `process-fork`/`process-exec` of any child — `posix_spawn`
returns `EPERM` before the child's own entitlements or trust ever matter — so a
normal, App-Store-signed app can never launch cupsd, the filters or the
Gutenprint backend. Running this runtime inside the app itself therefore
requires `com.apple.private.security.no-sandbox`, which Apple does not grant
(automatic signing rejects it) — so that is only an option for a jailbreak-only,
ad-hoc-signed build, never an App Store build. For an App-Store-publishable app
the CUPS+USB runtime must live in a **separate unsandboxed host** the app reaches
over IPP: a LAN bridge (Linux/Android/small device) for stock iOS, or a localhost
jailbreak daemon for the one-device case. The privileged USB/IOKit entitlements
stay on the helper either way.

For a jailbreak deployment, trust **all** executables under
`CupsRuntime.bundle/bin` using that jailbreak's installation mechanism. On
Dopamine the ad-hoc helper cdhash is added to the dynamic trustcache the first
time a jailbroken-context process spawns it, so once Runner is unsandboxed (and
injected, which a SpringBoard launch or a hooked debugserver provides) it can
spawn and auto-trust the pipeline. Ad-hoc build signatures are not a claim that
a particular jailbreak will trust them.

CUPS listens only on an ephemeral loopback port. Config, spool and printer
settings live under the app's Library/printing_ffi directory. The scheduler
holds an exclusive spool lock and exits when its owning app process exits,
preventing an orphan and a new app launch from processing the same jobs. All Dart worker
threads select the current app-owned port before native operations, including
after a scheduler restart. The CUPS web settings use the same bundled server. Consuming apps need an
`NSAppTransportSecurity` → `NSExceptionDomains` → `127.0.0.1` dictionary with
`NSExceptionAllowsInsecureHTTPLoads: true` for the WebView on iOS 17 and later.
The example and booth app include this loopback-only exception; they do not
enable arbitrary network loads. See [Apple's local networking documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

## Building and validation

An arm64 device build requires macOS, Xcode's iPhoneOS and macOS SDKs, CMake,
pkg-config, Python 3 and make. CocoaPods runs `tool/ios/build.sh` before compiling
the plugin. Tarball checksums are verified before extraction. The macOS SDK is
used only for IOKit's C declarations for libusb; binaries target iOS. Simulator
support is not included. `ios-cups.yml` builds the example device app without
Apple signing credentials.

Source downloads and build trees default to
`~/Library/Caches/printing_ffi-ios`; override `PRINTING_IOS_CACHE` if needed.
The finished runtime is copied into the pod's `CupsRuntime.bundle` resource and
static CUPS libraries into `ios/.build/arm64`. Build logic and SDK changes
invalidate the cache. Runtime driver licenses are bundled alongside the binaries;
see `LICENSING.md` for source/relinking obligations.

Linux validation covers Dart tests and the portable C launcher. It does not
validate Objective-C compilation, Apple signing, USB access, or physical output.
Before deployment, build on macOS and test these cases on devices:

- Stock iOS: app opens and remains usable; CUPS does not start.
- Permitted iPad, no printer: app opens; attach a supported printer and verify
  discovery, model-specific queue creation, and a successful photograph print.
- Denied USB interface: app remains usable and CUPS stays stopped.
- RX1/RX1HS and DS620: correct paper/strip options, job completion, media counts,
  ribbon/paper-end recovery, disconnect/reconnect, and preserved printer settings.
- Suspend/resume or terminate the scheduler: subsequent operations select the
  recovered scheduler, without duplicate print submission.
