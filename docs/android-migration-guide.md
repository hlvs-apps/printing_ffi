# Migration guide: adding the Android target to a printing_ffi app

Your Flutter app already uses `printing_ffi` on Linux/macOS/Windows (desktop
CUPS / Windows spooler). This guide adds **Android**: a bundled CUPS server for
office/network printing plus **DNP/Citizen dye-sub USB auto-detect** for photo
printers.

The good news: **almost nothing in your Dart changes.** Your existing
`listPrinters()` / `rawDataToPrinter()` / `printPdf()` / CUPS calls work on
Android against an in-app `cupsd` that the plugin boots for you. The Android-only
additions are one startup call, a few lines of Android build config, and an
optional manifest filter for USB auto-launch.

Unlike a desktop, Android has no system CUPS, so the plugin **cross-compiles CUPS
+ Gutenprint + libusb from source during your Gradle build** (nothing binary ships
in the plugin). This is the same model `flutter_fotobox_gphoto` uses for
libgphoto2.

---

## TL;DR checklist

- [ ] Build-host tools on every dev machine + CI runner: `autoconf automake libtool pkg-config patchelf make curl tar`.
- [ ] Android SDK + **NDK 27.0.12077973**.
- [ ] **Windows hosts: build under WSL2** (native Windows can't run autotools/patchelf; the plugin fails fast telling you so).
- [ ] `android/app/build.gradle(.kts)`: restrict to **arm64-v8a**, set **`useLegacyPackaging = true`**, pin **`ndkVersion "27.0.12077973"`**, **minSdk ≥ 24**.
- [ ] Boot at startup: `await PrintingFfi.instance.initializeAndroidCups();` (no-op off Android).
- [ ] (Optional, for DNP kiosk auto-launch) add the USB `DEVICE_ATTACHED` filter + `singleTop` to your launcher Activity.
- [ ] `flutter run` on an arm64 phone. First build is slow (it compiles CUPS + Gutenprint).

---

## 0. How Android differs from desktop (why these steps exist)

On desktop the plugin links the system `libcups`. Android has none and forbids
USB enumeration without root, so the plugin instead:

1. **compiles CUPS + Gutenprint + libusb from source** with the NDK during your
   Gradle build (hence the build-host tools), and boots a private `cupsd` inside
   your app sandbox on `127.0.0.1:<port>`; the FFI client talks to it exactly like
   desktop CUPS.
2. For DNP dye-sub USB printers, gets the device's **file descriptor** from
   Android's USB permission flow and hands it to the Gutenprint backend.

Both are handled by the plugin. You provide a working Android build environment
and one startup call.

---

## 1. Build-host prerequisites (dev machines + CI)

The from-source build runs wherever you build the app:

```bash
# macOS
brew install autoconf automake libtool pkg-config patchelf

# Debian/Ubuntu (CI)
sudo apt-get install -y autoconf automake libtool pkg-config patchelf make curl xz-utils
```

Install NDK **27.0.12077973** (`sdkmanager "ndk;27.0.12077973"`).

**Windows:** autotools + patchelf don't exist natively. Build the Android target
**inside WSL2** (Ubuntu) with the packages above. The plugin's build script
detects a native-Windows host and stops with a clear "run under WSL2" message.

> First build cross-compiles CUPS + Gutenprint + libusb + libpng/jpeg/tiff for
> arm64 (a few minutes). It's cached under `~/.gradle/printing-ffi-cups-cache` and
> survives `flutter clean`, so later builds are seconds. CI should cache `~/.gradle`.
> Offline first builds are not supported (sources are downloaded + SHA256-checked);
> once cached, builds are offline-friendly.

---

## 2. Align the Android build config

In your app's `android/app/build.gradle` (or `.kts`):

```kotlin
android {
    ndkVersion = "27.0.12077973"          // match the plugin

    defaultConfig {
        minSdk = 24                        // required by the plugin
        ndk { abiFilters += "arm64-v8a" }  // CUPS cross-build is arm64-only
    }

    // cupsd is exec()'d at runtime, so its .so must exist as real files on disk in
    // nativeLibraryDir. Modern AGP defaults useLegacyPackaging=false (libs mmap'd
    // from the APK, nothing to exec). Force it true.
    packaging { jniLibs { useLegacyPackaging = true } }
}
```

> **Manifest-merge caveat:** the plugin sets `android:extractNativeLibs="true"`.
> If your app explicitly sets it `false`, add
> `tools:replace="android:extractNativeLibs"` to your `<application>` (and the
> `xmlns:tools` namespace). This is the one manifest implication of the plugin.

Depend on the plugin as you already do (same dependency covers Android):

```yaml
dependencies:
  printing_ffi:
    git:
      url: <your printing_ffi git url>
      ref: <branch or tag>
```

---

## 3. Boot the Android port (one call)

cupsd has no desktop equivalent, so Android needs one startup call. It's a no-op
off Android, so it's safe to call unconditionally:

```dart
import 'package:printing_ffi/printing_ffi.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Boots the bundled cupsd + starts DNP USB auto-detect. No-op off Android.
  // Run after first frame so the platform channel is ready and the synchronous
  // cupsd-boot FFI stays off the startup focus window.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    PrintingFfi.instance.initializeAndroidCups();
  });
  runApp(const MyApp());
}
```

Observe progress + detected printers:

```dart
ValueListenableBuilder<String>(
  valueListenable: PrintingFfi.instance.cupsStatus,        // human-readable boot status
  builder: (_, status, __) => Text(status),
);
ValueListenableBuilder<List<DnpUsbPrinter>>(
  valueListenable: PrintingFfi.instance.dnpPrinters,       // auto-detected DNP printers
  builder: (_, printers, __) => Text('${printers.length} DNP printer(s)'),
);
```

After boot, your existing desktop calls work: `PrintingFfi.instance.listPrinters()`,
`addCupsPrinter(...)`, `rawDataToPrinter(...)`, `printPdf(...)`. A plugged-in,
permitted DNP printer is auto-added as a CUPS queue.

> **Concurrency note:** `initializeAndroidCups()` is single-flight (repeat calls
> dedupe). The cupsd-boot / add-printer FFI is synchronous and pinned to the
> calling isolate because libcups keeps target-server state thread-local — call it
> at startup and expect brief synchronous work; `Future` return does not make it
> non-blocking.

---

## 4. Open CUPS settings (no widgets to build)

The plugin ships the settings UI (an in-app WebView over the bundled cupsd web
interface). You just call a function:

```dart
// General CUPS admin page (/admin):
PrintingFfi.instance.openCupsSettings(context);

// A specific printer's properties/maintenance page (/printers/<name>):
PrintingFfi.instance.openCupsPrinterSettings(context, printerName: printer.name);
```

Both are no-ops (with a SnackBar) if cupsd isn't running yet. The UI follows the
device locale (a German phone shows German, English fallback otherwise).

---

## 5. (Recommended for DNP) USB auto-launch + remembered permission

For a photo kiosk you want: plug the DNP printer in → the app opens, already
permitted, no dialog. Add this to your **launcher** `<activity>` in
`AndroidManifest.xml` (it must be on your Activity — a plugin can't host a
launcher):

```xml
<activity android:name=".MainActivity" android:launchMode="singleTop" ...>
    ...
    <intent-filter>
        <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
    </intent-filter>
    <meta-data
        android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
        android:resource="@xml/printing_ffi_usb_device_filter" />
</activity>
```

`@xml/printing_ffi_usb_device_filter` is **shipped by the plugin** (covers the 12
DNP/Citizen VID/PIDs the Gutenprint `dnpds40` backend supports). `singleTop` is
required so a replug is delivered to the running app via `onNewIntent`. On first
connect Android offers "open this app for the printer?" with a "use by default"
checkbox — tick it once. The USB host feature, foreground service, and its
permissions all come from the plugin's manifest automatically.

---

## 6. Distribution

- Ship an **Android App Bundle** (`flutter build appbundle`). Only arm64 is built.
- CI: cache `~/.gradle` (includes `printing-ffi-cups-cache`) so CUPS isn't
  recompiled every run.
- **Licensing:** the Gutenprint DNP backend is GPL, run as a separate exec'd
  process (mere aggregation — your app + the MIT plugin stay as they are). The
  cross-built GPL binaries + their license notices ship in your APK; keep the
  offer-of-source obligation in mind for distribution. See `LICENSING.md`.

---

## 7. Gotchas / FAQ

- **First build takes minutes.** It's compiling CUPS + Gutenprint from source. Cached after.
- **CI fails "required build tool not found."** Install the step-1 packages on the runner.
- **Windows build fails.** Build the Android target under WSL2 (autotools/patchelf).
- **Offline first build fails.** Sources are downloaded on first build; do one online build to populate `~/.gradle/printing-ffi-cups-cache`, then you're offline-capable.
- **`ninja: libcups.a missing` after wiping only the Gradle cache.** The native build runs at CMake *configure*; run `flutter clean` (clears `.cxx`) so it reconfigures.
- **DNP printer not auto-added.** It must be one of the supported DNP/Citizen VID/PIDs and have USB permission. Check `adb logcat -s PrintingFfiCups PrintingFfiUsb`.
- **iOS.** Not supported (no cupsd-exec / USB-host path).

---

## What actually changed in your app

| Area | Change |
|------|--------|
| Dart code | one startup call (`initializeAndroidCups`) + optional `openCupsSettings*` |
| `pubspec.yaml` | none (same dependency; webview/shared_preferences come transitively) |
| `android/app/build.gradle` | arm64 filter, `useLegacyPackaging=true`, `ndkVersion`, `minSdk 24` |
| Build host / CI | install autotools + patchelf + NDK (WSL2 on Windows) |
| Manifest | optional USB-attach filter + `singleTop` on the launcher Activity |

Everything else — the native cross-compile, cupsd boot, asset extraction, USB
permission + fd handoff, DNP auto-add, the foreground service, the settings
WebView — is handled by the plugin.
