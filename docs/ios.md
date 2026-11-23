# CUPS printing on iOS

The iOS app is a **CUPS client only**. It never runs cupsd, opens USB or spawns a
process: iOS denies a sandboxed app `process-fork`/`process-exec` (`posix_spawn`
returns `EPERM`), and raw USB needs private IOKit entitlements Apple does not
grant. Both would break App Store signing. So the CUPS + USB runtime runs in a
separate, unsandboxed **host** that the app reaches over IPP:

- **On-device daemon** (jailbroken iPad, rootless Procursus: Dopamine,
  palera1n-rootless): `fotobox-cupsd`, a LaunchDaemon on `127.0.0.1:6310`.
- **LAN print bridge** (stock iOS, no jailbreak): a Linux box (Raspberry Pi,
  any Debian/Ubuntu machine) with the printer on USB, running the
  `fotobox-print-bridge` package ([bridge.md](bridge.md)). The app finds it with
  `CupsIos.instance.findBridges()` (DNS-SD `_fotobox-cups._tcp`), or takes its
  pairing link, and switches with `useServer('host:631', token: ...)`. The
  bridge answers only its local subnets and wants the token on every request.

The app prints to the queue the host offers — the host's default queue, else
its first. Which printers are supported is the host's business; the client has
no model list. Both hosts run the same queue manager (`tool/cups_host/fotobox_cupsd.c`):
it creates queues only for the Gutenprint DNP/Citizen dye-sub models, each with
its own PPD and never a raw or wrong-model fallback, defaults each queue's page
size to the paper loaded in the printer, and marks each new queue as the
default, so a printer attached later (a spare swapped in) is the one the app
uses.

Call `CupsIos.instance.watch()` after the first frame on the main Flutter engine.
Observe `ready`, `queueName` and `status`; use `PrintingFfi` only after
readiness, and keep the app usable when it is false. While foregrounded the host
is probed every five seconds (3 s connect timeout) and on resume, so a daemon
installed or a printer attached after launch needs no restart. Every Dart worker
thread selects the configured host before native operations.

## The on-device daemon

The app build produces the daemon package and ships it inside the plugin
framework (`com.fotobox.cupsd.deb`). `CupsIos.instance.installDaemon()` hands it
to the installed jailbreak package manager through the iOS open-in menu. Sileo
and Zebra both register as viewers for `org.debian.deb-archive`; the manager
runs `dpkg` and the package's maintainer scripts as root. The app never installs
anything itself, and no APT source is added, so `apt update` is unaffected.

Package layout (rootless, `Architecture: iphoneos-arm64`):

- `/var/jb/usr/lib/fotobox-cups/bin` — `fotobox-cupsd`, cupsd, the filters and
  the Gutenprint backend (ad-hoc signed; the backend carries the IOKit USB
  user-client entitlements).
- `/var/jb/usr/lib/fotobox-cups/share` — CUPS and Gutenprint data.
- `/var/jb/Library/LaunchDaemons/com.fotobox.cupsd.plist` — `KeepAlive`,
  `UserName mobile`.
- `/var/jb/var/lib/fotobox-cups` — writable state (config, spool, PPDs, logs;
  `fotobox-cupsd.log` is the daemon's own log). Created by `postinst`, owned by
  mobile; removed on purge.

`postinst` loads the job with `/var/jb/bin/launchctl load -w`, as Procursus'
own daemons do; `prerm` unloads it. No trustcache step: Dopamine's hooked
launchd trusts the daemon on spawn, and the daemon (hooked in turn) trusts what
it spawns. The daemon runs as **mobile**, not root: `start_cups_server` writes
`User #<uid>` and relies on a non-root cupsd (no privilege drop, no root
ownership checks on filters).

Every five seconds the daemon restarts cupsd if it died and runs the backend's
USB discovery (20 s timeout), creating a queue `<driver>_<hex serial>` for each
supported printer that has none. It never recreates an existing queue —
CUPS-Add-Modify-Printer with printer state restarts the active job and resets
the printer state, which would loop a print and undo an operator's Pause — and
it skips discovery while a job is printing so it never races the backend for the
USB interface. On SIGTERM (unload, upgrade) it stops cupsd with it, releasing
the port.

**Default page size.** Gutenprint's DNP PPDs default to their first size, 3.5x5
(`B7`), whatever is loaded. When the daemon creates a queue it asks the printer
which paper is loaded (the backend's own stats query, `BACKEND_STATS_ONLY`:
`"mediatype": "6x4 (PC)"`) and makes that paper's size the PPD default, the way
`lpadmin -o PageSize=...` does: 6x4 → `w288h432`, 6x8 → `w432h576`, 5x7, 6x9,
3.5x5, 8x10, 8x12. Paper it cannot read or has no size for falls back to 4x6
(`w288h432`); a PPD without 4x6 (8-inch printers) keeps Gutenprint's default.
This happens once per queue, recorded under `<state>/page-size-set/`: a queue an
older daemon created gets its size the first time this daemon sees its printer
(its PPD is replaced without touching printer state, so a Pause survives), and
afterwards the queue's defaults are the operator's. Jobs still carry their own
`media` (the app sends `w288h432` or `w288h432-div2`), so the default decides
what the CUPS web settings show and what every other option is matched against.

The CUPS web settings use the host's own web interface; on a bridge the WebView
answers its login with the token. Consuming apps need in `Info.plist`:

- `NSAppTransportSecurity` → `NSExceptionDomains` → `127.0.0.1` with
  `NSExceptionAllowsInsecureHTTPLoads: true`, and `NSAllowsLocalNetworking: true`
  for a bridge's `.local` name, for the WebView on iOS 17 and later. See
  [Apple's local networking documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).
- `NSLocalNetworkUsageDescription` (iOS asks before the first LAN connection)
  and `NSBonjourServices` containing `_fotobox-cups._tcp` (without it iOS refuses
  the browse). No multicast entitlement: DNS-SD browsing does not need one.
- `CFBundleURLTypes` with the URL scheme `fotobox-cups`, so a bridge's pairing
  QR code (`fotobox-cups://pair?server=...&token=...`, shown by
  `fotobox-print-bridge-pair`) opens the app from the Camera app. The plugin
  receives it through the app or scene delegate and publishes it on
  `CupsIos.instance.pairings`; the app decides whether to switch and remember.

## Building and validation

An arm64 device build requires macOS, Xcode's iPhoneOS and macOS SDKs, CMake,
pkg-config, Python 3, make and **dpkg** (`brew install dpkg`). CocoaPods runs, in
order: `tool/ios/build.sh` (the CUPS 2.4.19 / Gutenprint 5.3.5 / libusb 1.0.27 /
JPEG+PNG runtime, into `ios/Resources/CupsRuntime.bundle`),
`tool/ios/daemon/build_daemon_deb.sh` (compiles the daemon, packages the runtime
with `dpkg-deb`, checks the archive) and `tool/ios/embed_runtime.sh` (copies only
the `.deb` into the framework; the runtime never enters the app as code).
Tarball checksums are verified before extraction. Source downloads and build
trees default to `~/Library/Caches/printing_ffi-ios`; override
`PRINTING_IOS_CACHE` if needed. Simulator support is not included. Runtime
driver licenses travel with the binaries; see `LICENSING.md`.

Linux validation covers the Dart tests and the daemon + client C against a host
build of CUPS (real cupsd, stub USB backend): queue creation, the client probe,
submission through `submit_raw_data_job`, no discovery while printing, no queue
modification on later cycles, SIGTERM shutdown, and the package built with
`dpkg-deb` and unpacked by `dpkg`. The page size was checked the same way with
Gutenprint's real DS-RX1/DS620/DS820 PPDs: 3.5x5, 6x4 and 6x8 paper, unreadable
paper, an older queue updated once with its Pause kept. The bridge has its own
end-to-end test ([bridge.md](bridge.md#testing)). It does not validate Objective-C compilation,
Apple signing, the jailbreak's trust, USB access or physical output. On devices:

- Stock iOS: app opens and stays usable; printing unavailable until a LAN host.
- Stock iOS + bridge: "Find print bridge" lists it (Local Network prompt first);
  scanning the pairing QR with the Camera app switches the app to it.
- Jailbroken iPad: "Set up on-device printing" → package manager → install;
  `fotobox-cupsd.log` shows the uid (501) and the queue; app turns ready.
- The queue's default page size in the CUPS settings matches the loaded paper
  (4x6 paper: 4x6), also after upgrading from the 0.1 daemon.
- RX1/RX1HS and DS620: correct paper/strip options, job completion, media
  counts, ribbon/paper-end recovery, disconnect/reconnect, Pause survives.
- Package upgrade (newer app build) and removal: daemon reloads/stops cleanly.
