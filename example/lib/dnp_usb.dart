import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:printing_ffi/printing_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A DNP/Citizen USB dye-sub printer the app has detected and (optionally) opened.
@immutable
class DnpUsbPrinter {
  const DnpUsbPrinter({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.serial,
    required this.productName,
    required this.make,
    required this.modelName,
    required this.queueName,
    required this.ready,
  });

  /// Kernel device node, e.g. "/dev/bus/usb/001/002". Unique per attach.
  final String deviceName;
  final int vendorId;
  final int productId;

  /// USB serial (may be empty if not readable). Used for the queue name + persistence.
  final String serial;
  final String productName;

  /// Gutenprint dnpds40 "make" string, e.g. "dnp-ds620".
  final String make;
  final String modelName;

  /// The CUPS queue name created for this device (once [ready]).
  final String queueName;

  /// True once the fd-server is up and the CUPS queue is added (printable).
  final bool ready;

  /// Stable signature (vid:pid:serial) for persistence + dedupe.
  String get signature => '$vendorId:$productId:$serial';

  DnpUsbPrinter copyWith({String? queueName, bool? ready, String? serial}) => DnpUsbPrinter(
        deviceName: deviceName,
        vendorId: vendorId,
        productId: productId,
        serial: serial ?? this.serial,
        productName: productName,
        make: make,
        modelName: modelName,
        queueName: queueName ?? this.queueName,
        ready: ready ?? this.ready,
      );
}

/// Orchestrates DNP USB auto-detect end-to-end:
///
///   plug -> Kotlin detects + (auto or prompt) opens -> "opened" event with fd ->
///   startUsbFdServer(fd) -> addCupsPrinter(gutenprint53+usb URI) -> ready to print.
///   unplug -> "detached" event -> stopUsbFdServer + removeCupsPrinter + close.
///
/// Persistence: a device's signature (vid:pid:serial) is stored in
/// shared_preferences the first time it's opened; on app start / attach of a known
/// device that already has USB permission, Kotlin auto-opens it (no re-prompt) and
/// this class runs the add flow silently.
///
/// NOTE: built in the EXAMPLE app. Promoting to the plugin proper is a TODO.
class DnpUsb {
  DnpUsb._();
  static final DnpUsb instance = DnpUsb._();

  static const _method = MethodChannel('printing_ffi/usb');
  static const _events = EventChannel('printing_ffi/usb_events');
  static const _tag = 'PrintingFfiUsb';
  static const _prefsKey = 'dnp_usb_seen_signatures';

  StreamSubscription<dynamic>? _sub;
  bool _started = false;

  /// Fallback Gutenprint driver id if the detected model's "make" is unknown/empty.
  /// The DS620 driver is always generated at cupsd boot, so its PPD is guaranteed to
  /// exist. Per-model PPDs are generated on demand from the detected "make" (which is
  /// exactly the Gutenprint driver id, e.g. dnp-dsrx1) via [_resolvePpdPath].
  static const String _fallbackDriver = 'dnp-ds620';

  /// Human-readable status for an on-screen line.
  final ValueNotifier<String> status = ValueNotifier<String>(
    Platform.isAndroid ? 'DNP USB: idle' : 'DNP USB: Android only',
  );

  /// Currently-known DNP printers keyed by deviceName.
  final ValueNotifier<List<DnpUsbPrinter>> printers = ValueNotifier<List<DnpUsbPrinter>>(const []);

  final Map<String, DnpUsbPrinter> _byDevice = {};
  Set<String> _seen = {};

  static void _log(String msg) => debugPrint('[$_tag] $msg');

  /// Start listening for USB attach/detach and run an initial scan. Call once after
  /// cupsd is up (needs [PrintingFfi.instance.usbFdSockPath] to be non-null).
  Future<void> start() async {
    if (!Platform.isAndroid || _started) return;
    _started = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _seen = (prefs.getStringList(_prefsKey) ?? const []).toSet();
      _log('loaded ${_seen.length} previously-seen device signature(s)');
    } catch (e) {
      _log('prefs load failed: $e');
    }

    _sub = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) => _log('event stream error: $e'),
    );
    status.value = 'DNP USB: watching for printers';

    // Defer the initial scan OFF the startup / first-frame focus-acquisition window.
    // The scan can immediately emit an "opened" event whose handler (_onOpened) runs
    // synchronous FFI (startUsbFdServer + addCupsPrinter) on this UI isolate; running
    // that during the focus window starved input dispatch and caused an ANR ("Waited
    // 10000ms for FocusEvent"). A short delay after first frame lets the window gain
    // focus first; the auto-detect then happens a beat later without freezing the UI.
    Future.delayed(_initialScanDelay, () {
      if (!_started) return; // disposed in the meantime
      _log('running deferred initial scan');
      _method.invokeMethod('scan').catchError((Object e) {
        _log('scan failed: $e');
        return null;
      });
    });
  }

  /// Delay before the initial USB scan so the app can render + gain focus first
  /// (avoids the startup ANR). Attach/detach events after this still flow live.
  static const Duration _initialScanDelay = Duration(milliseconds: 1500);

  Future<void> _onEvent(dynamic raw) async {
    if (raw is! Map) return;
    final ev = raw['event'] as String?;
    final deviceName = raw['deviceName'] as String? ?? '';
    switch (ev) {
      case 'attached':
        // Matching device plugged in but no permission yet.
        final sig = '${raw['vendorId']}:${raw['productId']}:';
        final known = _seen.any((s) => s.startsWith(sig));
        _log('attached $deviceName known=$known (by vid:pid prefix)');
        status.value = 'DNP USB: printer attached (${raw['productId']})';
        // Whether known or new, request permission. For a known device with a
        // persisted "use by default" grant, Kotlin's hasPermission() is already
        // true and it will have auto-opened instead of emitting "attached".
        await requestPermission(deviceName);
        break;
      case 'opened':
        await _onOpened(raw);
        break;
      case 'detached':
        await _onDetached(deviceName);
        break;
      case 'permissionDenied':
        _log('permission denied for $deviceName');
        status.value = 'DNP USB: permission denied';
        break;
      case 'openFailed':
        _log('openDevice failed for $deviceName');
        status.value = 'DNP USB: open failed';
        break;
    }
  }

  Future<void> _onOpened(Map raw) async {
    final deviceName = raw['deviceName'] as String? ?? '';
    final fd = (raw['fd'] as num?)?.toInt() ?? -1;
    final serial = (raw['serial'] as String?) ?? '';
    final vid = (raw['vendorId'] as num?)?.toInt() ?? 0;
    final pid = (raw['productId'] as num?)?.toInt() ?? 0;
    final make = (raw['make'] as String?) ?? '';
    final modelName = (raw['modelName'] as String?) ?? '';
    final productName = (raw['productName'] as String?) ?? '';

    if (fd < 0) {
      _log('opened $deviceName but fd=$fd (invalid)');
      status.value = 'DNP USB: opened but no fd';
      return;
    }

    // Dedup: if this device is already added/ready, don't re-run the add flow (guards
    // against any duplicate "opened" event).
    final existing = _byDevice[deviceName];
    if (existing != null && existing.ready) {
      _log('opened $deviceName already ready; skipping duplicate add');
      return;
    }

    // Yield once so the platform can dispatch any pending frame/focus event before
    // the synchronous FFI below (startUsbFdServer + addCupsPrinter). MUST stay on
    // THIS isolate — libcups keeps the target cupsd in per-thread cupsSetServer
    // state, so these calls can't run on a background isolate; a same-isolate yield
    // is the safe way to avoid blocking input dispatch on a slow add.
    await Future<void>.delayed(Duration.zero);

    final queueName = _deriveQueueName(serial: serial, make: make, pid: pid);
    var printer = DnpUsbPrinter(
      deviceName: deviceName,
      vendorId: vid,
      productId: pid,
      serial: serial,
      productName: productName,
      make: make,
      modelName: modelName,
      queueName: queueName,
      ready: false,
    );
    _byDevice[deviceName] = printer;
    _publish();

    // --- the fd-handoff contract: fd-server FIRST, then add the queue. ---
    try {
      final sock = PrintingFfi.instance.usbFdSockPath;
      if (sock == null) {
        _log('usbFdSockPath is null (cupsd not booted?) — cannot serve fd');
        status.value = 'DNP USB: cupsd not ready';
        return;
      }
      PrintingFfi.instance.startUsbFdServer(sockPath: sock, fd: fd);
      _log('startUsbFdServer OK sock=$sock fd=$fd');

      // Generate/select the PPD for the ACTUAL detected model (e.g. DS-RX1 ->
      // dnp-dsrx1) and pass its ABSOLUTE path to addCupsPrinter, which uploads the
      // PPD file directly (no cups-driverd). Falls back to the always-present DS620
      // PPD, or to a plain "raw" queue if PPD generation is unavailable.
      final ppd = _resolvePpdPath(make);
      final model = ppd ?? 'raw';
      PrintingFfi.instance.addCupsPrinter(
        name: queueName,
        deviceUri: _deviceUri(serial: serial, make: make),
        model: model,
      );
      _log('addCupsPrinter OK name=$queueName model=$model');

      printer = printer.copyWith(ready: true);
      _byDevice[deviceName] = printer;
      _publish();
      status.value = 'DNP USB: ${modelName.isNotEmpty ? modelName : queueName} ready';

      await _remember(printer.signature);
    } catch (e) {
      _log('add flow failed: $e');
      status.value = 'DNP USB: add failed: $e';
    }
  }

  Future<void> _onDetached(String deviceName) async {
    final printer = _byDevice.remove(deviceName);
    _publish();
    if (printer == null) {
      _log('detached $deviceName (not tracked)');
      return;
    }
    _log('detached ${printer.queueName} — tearing down');
    status.value = 'DNP USB: ${printer.modelName} removed';

    // Reverse order of the attach flow: stop serving the fd, drop the queue,
    // then close the Kotlin-owned connection.
    try {
      PrintingFfi.instance.stopUsbFdServer();
    } catch (e) {
      _log('stopUsbFdServer failed: $e');
    }
    try {
      PrintingFfi.instance.removeCupsPrinter(name: printer.queueName);
    } catch (e) {
      _log('removeCupsPrinter failed: $e');
    }
    try {
      await _method.invokeMethod('closeDevice', {'deviceName': deviceName});
    } catch (e) {
      _log('closeDevice failed: $e');
    }
  }

  /// Ask Kotlin to (request permission if needed and) open a device by name.
  Future<void> requestPermission(String deviceName) async {
    try {
      await _method.invokeMethod('requestDevice', {'deviceName': deviceName});
    } catch (e) {
      _log('requestDevice failed: $e');
    }
  }

  /// Start the foreground service around a print job so Android doesn't kill the
  /// app mid dye-sub print. Call [endForegroundJob] when the job completes/fails.
  Future<void> beginForegroundJob({String text = 'Printing photo to DNP printer…'}) async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('startForegroundService', {'text': text});
    } catch (e) {
      _log('startForegroundService failed: $e');
    }
  }

  Future<void> endForegroundJob() async {
    if (!Platform.isAndroid) return;
    try {
      await _method.invokeMethod('stopForegroundService');
    } catch (e) {
      _log('stopForegroundService failed: $e');
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }

  // --- helpers ------------------------------------------------------------

  void _publish() {
    printers.value = List.unmodifiable(_byDevice.values);
  }

  Future<void> _remember(String signature) async {
    if (_seen.contains(signature)) return;
    _seen.add(signature);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, _seen.toList());
      _log('remembered device signature $signature');
    } catch (e) {
      _log('prefs save failed: $e');
    }
  }

  /// Resolve the absolute on-device PPD path for the detected model.
  ///
  /// [make] is the Gutenprint driver id (e.g. "dnp-dsrx1", "dnp-ds620"), which the
  /// native [generateDnpPpd] generates a PPD for and returns the absolute path of.
  /// The returned path is passed to addCupsPrinter, which uploads the PPD file
  /// directly (no cups-driverd). Falls back to the always-present DS620 PPD, then to
  /// null (caller uses a raw queue) if generation is unavailable.
  ///
  /// To extend to more DNP models: nothing to change here — any [make] that matches
  /// a Gutenprint `<printer driver="…"/>` in dyesub.xml resolves automatically.
  String? _resolvePpdPath(String make) {
    final driver = make.isNotEmpty ? make : _fallbackDriver;
    try {
      final path = PrintingFfi.instance.generateDnpPpd(driver);
      if (path != null && path.isNotEmpty) {
        _log('resolved PPD for driver=$driver -> $path');
        return path;
      }
    } catch (e) {
      _log('generateDnpPpd($driver) failed: $e');
    }
    // Fallback to the DS620 PPD generated at cupsd boot.
    if (driver != _fallbackDriver) {
      try {
        final path = PrintingFfi.instance.generateDnpPpd(_fallbackDriver);
        if (path != null && path.isNotEmpty) {
          _log('falling back to DS620 PPD -> $path');
          return path;
        }
      } catch (e) {
        _log('fallback generateDnpPpd($_fallbackDriver) failed: $e');
      }
    }
    _log('no PPD available for $driver; using raw queue');
    return null;
  }

  /// CUPS queue name — must be a valid CUPS printer name (no spaces/slashes).
  String _deriveQueueName({required String serial, required String make, required int pid}) {
    final base = make.isNotEmpty ? make.replaceAll('-', '_') : 'DNP_$pid';
    final suffix = serial.isNotEmpty ? '_${_sanitize(serial)}' : '';
    return 'DNP_$base$suffix';
  }

  /// Build the gutenprint53+usb device URI. Validated scheme (see
  /// .context/dnp-native-integration.md): `gutenprint53+usb://dnpds40/[serial]`.
  /// The backend parses backend_str="dnpds40" -> matches dnpds40_prefixes[] and
  /// loads the DNP driver. Since the app already selected the device (via fd),
  /// serial matching is advisory; the trailing path is informational.
  String _deviceUri({required String serial, required String make}) {
    final tail = serial.isNotEmpty ? _sanitize(serial) : (make.isNotEmpty ? make : 'usb');
    return 'gutenprint53+usb://dnpds40/$tail';
  }

  String _sanitize(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
}
