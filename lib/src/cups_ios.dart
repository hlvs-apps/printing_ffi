import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Optional in-app CUPS. Neither this facade nor its native probe loads the USB
/// library into the app. A sandbox denial simply leaves printing unavailable.
class CupsIos extends ChangeNotifier with WidgetsBindingObserver {
  CupsIos._();
  static final instance = CupsIos._();

  @visibleForTesting
  CupsIos.forTest({required this.invoke});

  @visibleForTesting
  Future<dynamic> Function(String method, Map<String, dynamic>? arguments)? invoke;

  static const _channel = MethodChannel('printing_ffi/ios_cups');
  final status = ValueNotifier<String>('CUPS: not started');
  int? port;
  String? queueName;
  bool get ready => port != null && queueName != null;
  Future<bool>? _pending;
  Timer? _retry;
  bool _observing = false;

  /// Call after the first frame on the main engine. Retry device discovery while
  /// foregrounded so attaching a printer after launch needs no app restart.
  void watch() {
    if (!Platform.isIOS || _observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    _resume();
  }

  void _resume() {
    unawaited(initialize());
    _retry ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(initialize());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The scheduler may have been killed while suspended. Native start checks
      // the owned child's status before reporting an existing session as ready.
      _resume();
    } else {
      _retry?.cancel();
      _retry = null;
    }
  }

  Future<dynamic> _call(String method, [Map<String, dynamic>? arguments]) => invoke?.call(method, arguments) ?? _channel.invokeMethod(method, arguments);

  /// Fail closed for printing, never for app startup. Concurrent callers share
  /// one attempt; unsuccessful attempts are retryable (permission/USB hot-plug).
  Future<bool> initialize() => _pending ??= _initialize().whenComplete(() {
    _pending = null;
  });

  Future<bool> _initialize() async {
    var stage = 'USB discovery';
    try {
      final discovery = await _call('discover');
      if (discovery is! String) {
        throw StateError('USB printer access unavailable');
      }
      final printers = parseDiscovery(discovery);
      if (printers.isEmpty) {
        final detail = discovery.trim();
        throw StateError(
          'No accessible supported USB printer'
          '${detail.isEmpty ? '' : ': ${detail.substring(0, detail.length > 4096 ? 4096 : detail.length)}'}',
        );
      }
      final printer = printers.first;
      stage = 'scheduler and queue setup';
      final result = await _call('start', printer);
      if (result is! Map || result['port'] is! int || (result['port'] as int) < 1 || (result['port'] as int) > 65535) {
        throw StateError('CUPS did not become ready');
      }
      port = result['port'] as int;
      queueName = printer['queueName'];
      _setStatus('CUPS: ${printer['driver']} ready');
      notifyListeners();
      return true;
    } catch (error) {
      port = null;
      queueName = null;
      _setStatus('CUPS unavailable ($stage): $error');
      notifyListeners();
      return false;
    }
  }

  void _setStatus(String value) {
    if (status.value == value) return;
    status.value = value;
    // flutter run must report the startup cause, not only downstream polling
    // failures. Repeated foreground probes with the same result stay quiet.
    debugPrint(value);
  }

  /// Use Gutenprint's exact device URI (including its encoded serial), never an
  /// inferred model or a DS620/raw fallback for a different dye-sub printer.
  @visibleForTesting
  static List<Map<String, String>> parseDiscovery(String output) {
    const drivers = {
      'citizen-cw-01',
      'dnp-ds40',
      'dnp-ds80',
      'dnp-dsrx1',
      'citizen-cw-02',
      'dnp-ds80dx',
      'citizen-cx-02',
      'citizen-cx-02w',
      'citizen-cz-01',
      'dnp-ds620',
      'dnp-ds820',
      'dnp-qw410',
    };
    final result = <Map<String, String>>[];
    for (final line in output.split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 2 || fields.first != 'direct') continue;
      final uri = Uri.tryParse(fields[1]);
      if (uri == null || uri.scheme != 'gutenprint53+usb' || !drivers.contains(uri.host) || uri.pathSegments.length != 1 || uri.pathSegments.single.isEmpty || uri.hasQuery || uri.hasFragment) {
        continue;
      }
      // Encode the entire URI injectively; replacing punctuation with '_' can
      // collide for two physical serials and silently reuse the wrong queue.
      final serial = uri.pathSegments.single.codeUnits.map((c) => c.toRadixString(16).padLeft(4, '0')).join();
      final queue = '${uri.host}_$serial';
      if (queue.length > 127) continue;
      result.add({'uri': fields[1], 'driver': uri.host, 'queueName': queue});
    }
    return result;
  }

  @override
  void dispose() {
    _retry?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    status.dispose();
    super.dispose();
  }
}
