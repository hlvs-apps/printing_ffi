import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:printing_ffi/printing_ffi.dart';

/// Internal boot facade for the bundled Android cupsd. Not part of the public API;
/// drive it via [PrintingFfi.initializeAndroidCups] and observe
/// [PrintingFfi.cupsStatus] / [PrintingFfi.dnpPrinters].
///
/// On Android it: fetches the extracted asset/lib paths from the Kotlin plugin
/// (`printing_ffi/cups` -> `getCupsPaths`), boots the in-app cupsd via
/// [PrintingFfi.startCupsServer], points the libcups client at it, then starts the
/// DNP USB auto-detect layer ([DnpUsb]).
///
/// Concurrency (C13): [boot] is single-flight — concurrent/repeat calls dedupe onto
/// one in-flight boot; a completed boot returns immediately. [reset] (called after
/// [PrintingFfi.stopCupsServer]) clears the latch so a later [boot] can reboot.
///
/// ANR/threading (C14): the boot runs synchronous FFI (start_cups_server, and
/// downstream add_cups_printer during DNP auto-add) pinned to the CALLING (root/UI)
/// isolate because libcups keeps its target-server in thread-local `cupsSetServer`
/// state — this work cannot be moved to a helper isolate without missing the in-app
/// cupsd. Callers should invoke [PrintingFfi.initializeAndroidCups] at startup and
/// expect brief synchronous work; the DNP layer defers its own initial USB scan a
/// beat after first frame to keep that off the focus-acquisition window (whose
/// starvation caused "Waited 10000ms for FocusEvent" ANRs).
class CupsAndroidBoot {
  CupsAndroidBoot._();

  /// The singleton backing [PrintingFfi.initializeAndroidCups].
  static final CupsAndroidBoot instance = CupsAndroidBoot._();

  static const _channel = MethodChannel('printing_ffi/cups');
  static const _tag = 'PrintingFfiCups';

  /// Human-readable status for an on-screen banner. Mirrored by
  /// [PrintingFfi.cupsStatus].
  final ValueNotifier<String> status = ValueNotifier<String>(
    Platform.isAndroid ? 'CUPS: not started' : 'CUPS bundled server: Android only',
  );

  /// The detected DNP printers (mirrors [DnpUsb.instance.printers]); surfaced as
  /// [PrintingFfi.dnpPrinters].
  ValueNotifier<List<DnpUsbPrinter>> get dnpPrinters => DnpUsb.instance.printers;

  /// The in-flight (or completed) boot, or null before the first [boot]/after
  /// [reset]. Single-flight latch (C13).
  Future<void>? _bootFuture;

  static void _log(String msg) {
    debugPrint('[$_tag] $msg');
  }

  /// Boots cupsd + starts DNP auto-detect. Single-flight and idempotent: concurrent
  /// or repeated calls await the same in-flight boot; once it has completed, returns
  /// immediately. No-op off Android.
  Future<void> boot() {
    if (!Platform.isAndroid) {
      _log('Not Android; skipping bundled cupsd boot.');
      return Future<void>.value();
    }
    return _bootFuture ??= _boot();
  }

  /// Clears the single-flight latch so a subsequent [boot] can reboot (call after
  /// [PrintingFfi.stopCupsServer]).
  void reset() {
    _bootFuture = null;
    if (Platform.isAndroid) {
      status.value = 'CUPS: not started';
    }
  }

  Future<void> _boot() async {
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
      _log('cupsd started on 127.0.0.1:$port');
      status.value = 'CUPS: cupsd up on :$port';

      await _probePrinters(context: 'after boot', port: port);

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
  Future<void> _probePrinters({required String context, required int port}) async {
    try {
      final printers = PrintingFfi.instance.listPrinters();
      _log('get_printers ($context): ${printers.length} printer(s) '
          '-> ${printers.map((p) => "${p.name}@${p.url}").toList()}');
      if (printers.isEmpty) {
        status.value = 'CUPS: get_printers OK on :$port (0 printers) = SUCCESS';
      } else {
        status.value =
            'CUPS: get_printers OK on :$port (${printers.length}): '
            '${printers.map((p) => p.name).join(", ")}';
      }
    } catch (e, st) {
      _log('get_printers FAILED: $e\n$st');
      status.value = 'CUPS: get_printers FAILED: $e';
    }
  }
}
