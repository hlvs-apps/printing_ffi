import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printing_ffi/src/cups_ios.dart';

void main() {
  test('an unreachable host leaves printing unavailable, retryable', () async {
    var reachable = false;
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'configure') return null;
        if (!reachable) {
          throw PlatformException(code: 'unavailable', message: 'connection refused');
        }
        return {'queueName': 'dnp-ds620_313233', 'model': 'DNP DS620'};
      },
    );
    expect(await cups.initialize(), false);
    expect(cups.ready, false);
    expect(cups.status.value, contains('printer discovery'));
    expect(cups.status.value, contains('connection refused'));
    // A host coming up later needs no restart.
    reachable = true;
    expect(await cups.initialize(), true);
    expect(cups.ready, true);
    expect(cups.queueName, 'dnp-ds620_313233');
    cups.dispose();
  });

  test('configure failure reports the connect stage, not printer discovery', () async {
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'configure') {
          throw PlatformException(code: 'unavailable', message: 'bad server string');
        }
        return {'queueName': 'x'};
      },
    );
    expect(await cups.initialize(), false);
    expect(cups.status.value, contains('connect'));
    expect(cups.status.value, isNot(contains('printer discovery')));
    expect(cups.status.value, contains('bad server string'));
    cups.dispose();
  });

  test('the queue the host offers makes the client ready', () async {
    final seen = <String>[];
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        seen.add(method);
        if (method == 'configure') {
          expect(arguments!['server'], '127.0.0.1:6310');
          return null;
        }
        return {'queueName': 'dnp-dsrx1_52583120', 'model': 'DNP DS-RX1'};
      },
    );
    expect(await cups.initialize(), true);
    expect(cups.ready, true);
    expect(cups.queueName, 'dnp-dsrx1_52583120');
    expect(cups.status.value, contains('DNP DS-RX1'));
    expect(cups.status.value, contains('127.0.0.1:6310'));
    expect(seen, ['configure', 'probe']);
    cups.dispose();
  });

  test('any queue name the host offers is accepted; the client has no model list', () async {
    // A LAN bridge names its queues its own way; the client must not care.
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async =>
          method == 'configure' ? null : {'queueName': 'Booth_Printer', 'model': ''},
    );
    expect(await cups.initialize(), true);
    expect(cups.queueName, 'Booth_Printer');
    // No model reported: the status names the queue instead.
    expect(cups.status.value, contains('Booth_Printer'));
    cups.dispose();
  });

  test('a reachable host with no queue stays unavailable', () async {
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async =>
          method == 'configure' ? null : {'detail': 'host offers no printer queue yet'},
    );
    expect(await cups.initialize(), false);
    expect(cups.ready, false);
    expect(cups.status.value, contains('No printer queue on 127.0.0.1:6310'));
    expect(cups.status.value, contains('host offers no printer queue yet'));
    cups.dispose();
  });

  test('health revoke drops readiness; a restored host restores it', () async {
    var reachable = true;
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'configure') return null;
        if (!reachable) throw PlatformException(code: 'unavailable');
        return {'queueName': 'dnp-ds620_313233', 'model': 'DNP DS620'};
      },
    );
    expect(await cups.initialize(), true);
    reachable = false;
    expect(await cups.initialize(), false);
    expect(cups.ready, false);
    reachable = true;
    expect(await cups.initialize(), true);
    cups.dispose();
  });

  test('overlapping attempts run one configure and one probe', () async {
    final probe = Completer<Map>();
    var configures = 0;
    var probes = 0;
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'configure') {
          configures++;
          return null;
        }
        probes++;
        return probe.future;
      },
    );
    final first = cups.initialize();
    final second = cups.initialize();
    probe.complete({'queueName': 'dnp-ds620_313233', 'model': 'DNP DS620'});
    expect(await first, true);
    expect(await second, true);
    expect(configures, 1);
    expect(probes, 1);
    cups.dispose();
  });

  test('malformed probe responses never enable printing', () async {
    for (final response in <Object?>[
      null,
      {},
      {'model': 'DNP DS620'},
      {'queueName': ''},
      {'queueName': 123},
      {'queueName': 'q' * 128}, // over the 127-char CUPS limit
    ]) {
      final cups = CupsIos.forTest(
        invoke: (method, arguments) async => method == 'configure' ? null : response,
      );
      expect(await cups.initialize(), false, reason: 'response: $response');
      expect(cups.ready, false);
      expect(cups.queueName, null);
      cups.dispose();
    }
  });

  test('installDaemon forwards to the native open-in and reports why it failed', () async {
    for (final (native, expected) in <(Object?, CupsDaemonInstall)>[
      ('presented', CupsDaemonInstall.presented),
      ('missing-package', CupsDaemonInstall.missingPackage),
      ('no-package-manager', CupsDaemonInstall.noPackageManager),
      ('no-window', CupsDaemonInstall.noWindow),
      (null, CupsDaemonInstall.noPackageManager),
    ]) {
      final calls = <String>[];
      final cups = CupsIos.forTest(
        invoke: (method, arguments) async {
          calls.add(method);
          return native;
        },
      );
      expect(await cups.installDaemon(), expected);
      expect(calls, ['installDaemon']);
      cups.dispose();
    }
  });

  test('useServer switches the host endpoint and re-probes it', () async {
    final servers = <String>[];
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'configure') {
          servers.add(arguments!['server'] as String);
          return null;
        }
        return {'queueName': 'dnp-ds620_313233', 'model': 'DNP DS620'};
      },
    );
    expect(await cups.initialize(), true);
    expect(await cups.useServer('10.0.0.5:6310'), true);
    expect(cups.server, '10.0.0.5:6310');
    expect(servers, ['127.0.0.1:6310', '10.0.0.5:6310']);
    cups.dispose();
  });

  test('a LAN bridge is configured with its user and token', () async {
    final configured = <Map<String, dynamic>?>[];
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'configure') {
          configured.add(arguments);
          return null;
        }
        return {'queueName': 'dnp-dsrx1_52583120', 'model': 'DNP DS-RX1'};
      },
    );
    expect(await cups.useServer('booth-pi.local:631', token: ' abcd-efgh '), true);
    expect(cups.onDevice, false);
    expect(configured.last, {
      'server': 'booth-pi.local:631',
      'user': kBridgeUser,
      'token': 'abcd-efgh',
    });
    expect(cups.status.value, contains('booth-pi.local:631'));
    // Back on the device: no credentials go to the loopback daemon.
    expect(await cups.useServer(kDefaultCupsServer), true);
    expect(cups.onDevice, true);
    expect(configured.last, {'server': kDefaultCupsServer, 'user': null, 'token': null});
    cups.dispose();
  });

  test('a new token alone re-probes the same host', () async {
    var probes = 0;
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'configure') return null;
        probes++;
        return {'queueName': 'q'};
      },
    );
    await cups.useServer('10.0.0.5:631', token: 'one');
    expect(cups.queueName, 'q');
    await cups.useServer('10.0.0.5:631', token: 'two');
    expect(cups.token, 'two');
    expect(probes, 2);
    cups.dispose();
  });

  test('findBridges keeps resolved bridges and drops malformed entries', () async {
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        expect(method, 'browse');
        expect(arguments!['seconds'], 2.5);
        return [
          {'name': 'Fotobox print bridge on booth-pi', 'host': 'booth-pi.local', 'port': 631},
          {'host': '10.0.0.9', 'port': 631},
          {'name': 'no host', 'port': 631},
          {'name': 'bad port', 'host': 'x.local', 'port': '631'},
          'garbage',
        ];
      },
    );
    final bridges = await cups.findBridges(timeout: const Duration(milliseconds: 2500));
    expect(bridges.map((b) => b.endpoint), ['booth-pi.local:631', '10.0.0.9:631']);
    expect(bridges.first.name, 'Fotobox print bridge on booth-pi');
    expect(bridges.last.name, '10.0.0.9');
    cups.dispose();
  });

  test('pairing links reach listeners; malformed ones are ignored', () async {
    final cups = CupsIos.forTest(invoke: (method, arguments) async => null);
    final received = <CupsPairing>[];
    final sub = cups.pairings.listen(received.add);
    cups.receivePairing({'server': 'booth-pi.local:631', 'token': 'abcd'});
    cups.receivePairing({'token': 'no server'});
    cups.receivePairing(null);
    await Future<void>.delayed(Duration.zero);
    expect(received.map((p) => '${p.server} ${p.token}'), ['booth-pi.local:631 abcd']);
    await sub.cancel();
    cups.dispose();
  });
}
