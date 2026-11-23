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
        return {'queueName': 'dnp-ds620_313233', 'driver': 'dnp-ds620'};
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

  test('a supported DNP queue on the host makes the client ready', () async {
    final seen = <String>[];
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        seen.add(method);
        if (method == 'configure') {
          expect(arguments!['server'], '127.0.0.1:6310');
          return null;
        }
        return {'queueName': 'dnp-dsrx1_52583120', 'driver': 'dnp-dsrx1'};
      },
    );
    expect(await cups.initialize(), true);
    expect(cups.ready, true);
    expect(cups.queueName, 'dnp-dsrx1_52583120');
    expect(cups.status.value, contains('dnp-dsrx1'));
    expect(cups.status.value, contains('127.0.0.1:6310'));
    expect(seen, ['configure', 'probe']);
    cups.dispose();
  });

  test('a reachable host with no supported printer stays unavailable', () async {
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async =>
          method == 'configure' ? null : {'detail': 'no supported queues on host'},
    );
    expect(await cups.initialize(), false);
    expect(cups.ready, false);
    expect(cups.status.value, contains('No accessible supported printer'));
    expect(cups.status.value, contains('no supported queues on host'));
    cups.dispose();
  });

  test('health revoke drops readiness; a restored host restores it', () async {
    var reachable = true;
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'configure') return null;
        if (!reachable) throw PlatformException(code: 'unavailable');
        return {'queueName': 'dnp-ds620_313233', 'driver': 'dnp-ds620'};
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
    probe.complete({'queueName': 'dnp-ds620_313233', 'driver': 'dnp-ds620'});
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
      {'driver': 'dnp-ds620'},
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

  test('installDaemon forwards to the native open-in and reports the result', () async {
    for (final (native, expected) in <(Object?, bool)>[(true, true), (false, false), (null, false)]) {
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
        return {'queueName': 'dnp-ds620_313233', 'driver': 'dnp-ds620'};
      },
    );
    expect(await cups.initialize(), true);
    expect(await cups.useServer('10.0.0.5:6310'), true);
    expect(cups.server, '10.0.0.5:6310');
    expect(servers, ['127.0.0.1:6310', '10.0.0.5:6310']);
    cups.dispose();
  });
}
