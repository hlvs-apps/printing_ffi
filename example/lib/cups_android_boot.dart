import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:printing_ffi/printing_ffi.dart';

import 'dnp_usb.dart';

/// Phase 1 milestone driver: on Android, boot the bundled cupsd inside the app
/// sandbox (app uid), then prove the in-app libcups client can do an IPP
/// get_printers round-trip against it (empty list = success).
///
/// All progress is logged under the "PrintingFfiCups" tag so it shows in:
///   adb logcat -s PrintingFfiCups flutter
///
/// Results are exposed via [CupsAndroidBoot.status] (a ValueNotifier) so the UI
/// can show a banner without coupling to the rest of the example app.
class CupsAndroidBoot {
  CupsAndroidBoot._();

  static const _channel = MethodChannel('printing_ffi/cups');
  static const _tag = 'PrintingFfiCups';

  /// Human-readable status for an on-screen banner.
  static final ValueNotifier<String> status = ValueNotifier<String>(
    Platform.isAndroid ? 'CUPS: not started' : 'CUPS bundled server: Android only',
  );

  static int? _port;
  static bool _started = false;

  /// The localhost port the bundled cupsd is listening on, or null if not started.
  /// Used by the example to open the CUPS web interface in a WebView.
  static int? get port => _port;

  static void _log(String msg) {
    // ignore: avoid_print
    debugPrint('[$_tag] $msg');
  }

  /// Boots cupsd and runs get_printers. Safe to call once at startup.
  static Future<void> bootAndProbe() async {
    if (!Platform.isAndroid) {
      _log('Not Android; skipping bundled cupsd boot.');
      return;
    }
    if (_started) return;
    _started = true;

    try {
      status.value = 'CUPS: fetching paths...';
      final paths = await _channel.invokeMapMethod<String, String>('getCupsPaths');
      if (paths == null) {
        status.value = 'CUPS: getCupsPaths returned null';
        _log('getCupsPaths returned null');
        return;
      }
      final nativeLibDir = paths['nativeLibDir']!;
      final serverRoot = paths['serverRoot']!;
      final dataDir = paths['dataDir']!;
      final docRoot = paths['docRoot'];
      _log('paths: nativeLibDir=$nativeLibDir serverRoot=$serverRoot dataDir=$dataDir docRoot=$docRoot');

      status.value = 'CUPS: starting cupsd...';
      final port = PrintingFfi.instance.startCupsServer(
        serverRoot: serverRoot,
        nativeLibDir: nativeLibDir,
        dataDir: dataDir,
        docRoot: docRoot,
      );
      _port = port;
      _log('cupsd started on 127.0.0.1:$port');
      status.value = 'CUPS: cupsd up on :$port';

      await _probePrinters(context: 'after boot');

      // cupsd is up (usbFdSockPath is now valid) -> start the DNP USB auto-detect
      // layer: watch for attach/detach, and auto-add a queue for any already-plugged,
      // already-permitted DNP printer.
      //
      // IMPORTANT (ANR fix): the DNP add flow (_onOpened) runs SYNCHRONOUS FFI
      // (startUsbFdServer + addCupsPrinter) on THIS (UI) isolate and MUST stay here
      // (libcups keeps the target cupsd in per-thread cupsSetServer state — moving it
      // to another isolate would miss the in-app cupsd). To keep it off the startup
      // focus-acquisition window (whose starvation caused "Waited 10000ms for
      // FocusEvent" ANRs), do NOT await it here and let DnpUsb.start() defer its own
      // initial scan a beat after the app is interactive. Fire-and-forget.
      unawaited(DnpUsb.instance.start());
    } catch (e, st) {
      _log('boot failed: $e\n$st');
      status.value = 'CUPS: boot FAILED: $e';
    }
  }

  /// Runs get_printers via the FFI client and logs the result.
  static Future<void> _probePrinters({required String context}) async {
    try {
      final printers = PrintingFfi.instance.listPrinters();
      _log('get_printers ($context): ${printers.length} printer(s) '
          '-> ${printers.map((p) => "${p.name}@${p.url}").toList()}');
      if (printers.isEmpty) {
        status.value = 'CUPS: get_printers OK on :$_port (0 printers) = SUCCESS';
      } else {
        status.value =
            'CUPS: get_printers OK on :$_port (${printers.length}): '
            '${printers.map((p) => p.name).join(", ")}';
      }
    } catch (e, st) {
      _log('get_printers FAILED: $e\n$st');
      status.value = 'CUPS: get_printers FAILED: $e';
    }
  }

  /// Adds a raw socket:// queue, then re-lists to prove it appears.
  /// Returns true on success. [deviceUri] defaults to a dev-Mac fake printer
  /// (see tool/android/fake-printer.sh); change it in the UI field to your host.
  static Future<bool> addTestPrinter({
    String name = 'test',
    String deviceUri = 'socket://192.168.2.165:9100',
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      status.value = 'CUPS: adding $name -> $deviceUri ...';
      _log('adding printer $name -> $deviceUri (raw)');
      PrintingFfi.instance.addCupsPrinter(
        name: name,
        deviceUri: deviceUri,
        model: 'raw',
      );
      _log('add_cups_printer OK; re-listing');
      await _probePrinters(context: 'after add_cups_printer');
      return true;
    } catch (e, st) {
      _log('add_cups_printer FAILED: $e\n$st');
      status.value = 'CUPS: add printer FAILED: $e';
      return false;
    }
  }
}
