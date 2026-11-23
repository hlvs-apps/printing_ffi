import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The loopback endpoint the on-device CUPS daemon listens on (topology L: a
/// jailbreak LaunchDaemon on the same device). A LAN print bridge (topology B,
/// `tool/bridge/`) replaces it with a found, paired or entered `host:port`.
const String kDefaultCupsServer = '127.0.0.1:6310';

/// The CUPS user a LAN print bridge knows the app as; the bridge's token is its
/// password (HTTP Basic, see `tool/bridge/cupsd.conf`).
const String kBridgeUser = 'fotobox-print';

/// A print bridge found on the LAN (it advertises `_fotobox-cups._tcp`).
@immutable
class CupsBridge {
  const CupsBridge({required this.name, required this.host, required this.port});

  /// The advertised name, e.g. "Fotobox print bridge on booth-pi".
  final String name;
  final String host;
  final int port;

  /// What [CupsIos.useServer] takes.
  String get endpoint => '$host:$port';
}

/// A bridge's pairing link (`fotobox-cups://pair?server=...&token=...`), read
/// from the QR code `fotobox-print-bridge-pair` prints, via the Camera app.
@immutable
class CupsPairing {
  const CupsPairing({required this.server, required this.token});
  final String server;
  final String token;
}

/// Outcome of [CupsIos.installDaemon].
enum CupsDaemonInstall {
  /// The open-in menu is up; the user picks Sileo, Zebra, ... to install.
  presented,

  /// This build of the app ships no daemon package.
  missingPackage,

  /// Nothing on the device opens a `.deb` (no jailbreak package manager).
  noPackageManager,

  /// The app had no foreground window to present from; retry.
  noWindow,
}

/// iOS CUPS **client**. The app never runs cupsd, opens USB, or spawns a
/// process — iOS forbids a sandboxed app from both. Instead it points the
/// in-process libcups client at an external CUPS host (a localhost jailbreak
/// daemon, or a LAN bridge) and prints to the queue that host offers: its
/// default, else its first. Which printers are supported is the host's
/// business; the client carries no model list. A host that is unreachable or
/// offers no queue simply leaves printing unavailable; the app stays usable and
/// degrades, never refuses.
///
/// Public surface is unchanged from the old in-app-cupsd facade ([ready],
/// [queueName], [status], [watch], [initialize]) so `printing.dart` and the
/// settings UI need no changes. What changed is the native protocol: `configure`
/// (point libcups at [server]) + `probe` (read back the host's queue),
/// replacing the old `discover` (USB) + `start` (fork cupsd).
class CupsIos extends ChangeNotifier with WidgetsBindingObserver {
  CupsIos._();
  static final instance = CupsIos._();

  @visibleForTesting
  CupsIos.forTest({required this.invoke, String? server})
      : server = server ?? kDefaultCupsServer;

  @visibleForTesting
  Future<dynamic> Function(String method, Map<String, dynamic>? arguments)?
      invoke;

  static const _channel = MethodChannel('printing_ffi/ios_cups');
  final status = ValueNotifier<String>('CUPS: not started');

  /// The CUPS host endpoint (`host:port`). Defaults to the localhost daemon;
  /// set via [useServer] to a LAN print bridge.
  String server = kDefaultCupsServer;

  /// The LAN bridge's token, sent as [kBridgeUser]'s password. Null for the
  /// on-device daemon, which asks for none.
  String? token;

  /// Whether [server] is the on-device daemon rather than a LAN bridge.
  bool get onDevice => server == kDefaultCupsServer;

  /// Pairing links opened while the app runs (or that launched it). The app
  /// decides whether to [useServer] them and to remember them.
  Stream<CupsPairing> get pairings => _pairings.stream;
  final _pairings = StreamController<CupsPairing>.broadcast();

  String? queueName;
  String? _model;

  /// Ready to print: [server] offers a queue.
  bool get ready => queueName != null;

  Future<bool>? _pending;
  Timer? _retry;
  bool _observing = false;

  /// Hand the app-bundled daemon `.deb` to the installed jailbreak package
  /// manager (Sileo, Zebra, ...) through the iOS open-in menu, so the user
  /// installs the on-device CUPS daemon (topology L) in one tap. The app never
  /// performs the privileged install itself; the manager (root) does.
  Future<CupsDaemonInstall> installDaemon() async =>
      switch (await _call('installDaemon')) {
        'presented' => CupsDaemonInstall.presented,
        'missing-package' => CupsDaemonInstall.missingPackage,
        'no-window' => CupsDaemonInstall.noWindow,
        _ => CupsDaemonInstall.noPackageManager,
      };

  /// Point the client at a different CUPS host: a LAN bridge with its
  /// [token], or [kDefaultCupsServer] for the on-device daemon. Re-probes.
  Future<bool> useServer(String endpoint, {String? token}) {
    final cleaned = (token == null || token.trim().isEmpty) ? null : token.trim();
    if (endpoint != server || cleaned != this.token) {
      server = endpoint;
      this.token = cleaned;
      queueName = null;
      _model = null;
    }
    return initialize();
  }

  /// Look for print bridges on the LAN (DNS-SD `_fotobox-cups._tcp`) for
  /// [timeout]. Needs the app's Local Network permission; throws a
  /// [PlatformException] when iOS refuses the browse.
  Future<List<CupsBridge>> findBridges({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final found = await _call('browse', {'seconds': timeout.inMilliseconds / 1000});
    if (found is! List) return const [];
    return [
      for (final bridge in found)
        if (bridge is Map &&
            bridge['host'] is String &&
            (bridge['host'] as String).isNotEmpty &&
            bridge['port'] is int)
          CupsBridge(
            name: bridge['name'] is String ? bridge['name'] as String : bridge['host'] as String,
            host: bridge['host'] as String,
            port: bridge['port'] as int,
          ),
    ];
  }

  /// A pairing link from the native side (`{server, token}`); anything else is
  /// ignored.
  @visibleForTesting
  void receivePairing(Object? link) {
    if (link is! Map) return;
    final server = link['server'];
    final token = link['token'];
    if (server is! String || server.isEmpty) return;
    _pairings.add(CupsPairing(server: server, token: token is String ? token : ''));
  }

  /// Call after the first frame on the main engine. Re-probes the host while
  /// foregrounded so attaching a printer (or the daemon coming up) after launch
  /// needs no app restart.
  void watch() {
    if (!Platform.isIOS || _observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'paired') throw MissingPluginException();
      receivePairing(call.arguments);
    });
    // A pairing link that launched the app arrived before this handler.
    unawaited(_call('takePairing').then(receivePairing, onError: (_) {}));
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
      _resume();
    } else {
      _retry?.cancel();
      _retry = null;
    }
  }

  Future<dynamic> _call(String method, [Map<String, dynamic>? arguments]) =>
      invoke?.call(method, arguments) ??
      _channel.invokeMethod(method, arguments);

  /// Fail closed for printing, never for app startup. Concurrent callers share
  /// one attempt; unsuccessful attempts are retryable (host down, printer not
  /// yet attached, daemon still starting).
  Future<bool> initialize() => _pending ??= _initialize().whenComplete(() {
        _pending = null;
      });

  Future<bool> _initialize() async {
    var stage = 'connect';
    try {
      // Point libcups at the host. Cheap and local; it only stores the target.
      await _call('configure', {
        'server': server,
        'user': token == null ? null : kBridgeUser,
        'token': token,
      });
      stage = 'printer discovery';
      // Ask the host which queue to print to. The host (daemon or bridge) ran
      // the USB discovery and created the queue; the app only reads it back
      // over IPP. Unreachable host throws; reachable-but-no-printer returns a
      // map without a queueName.
      final probe = await _call('probe');
      final name = (probe is Map) ? probe['queueName'] : null;
      if (name is! String || name.isEmpty || name.length > 127) {
        final detail = (probe is Map && probe['detail'] is String)
            ? ': ${(probe['detail'] as String).trim()}'
            : '';
        throw StateError('No printer queue on $server$detail');
      }
      queueName = name;
      final model = (probe is Map) ? probe['model'] : null;
      _model = (model is String && model.trim().isNotEmpty) ? model.trim() : null;
      _setStatus('CUPS: ${_model ?? name} on $server ready');
      notifyListeners();
      return true;
    } catch (error) {
      queueName = null;
      _model = null;
      _setStatus('CUPS unavailable ($stage): $error');
      notifyListeners();
      return false;
    }
  }

  void _setStatus(String value) {
    if (status.value == value) return;
    status.value = value;
    // flutter run must report the real startup cause, not only downstream
    // polling failures. Repeated foreground probes with the same result stay
    // quiet.
    debugPrint(value);
  }

  @override
  void dispose() {
    _retry?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    unawaited(_pairings.close());
    status.dispose();
    super.dispose();
  }
}
