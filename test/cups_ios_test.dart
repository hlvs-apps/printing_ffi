import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printing_ffi/src/cups_ios.dart';

void main() {
  test('a failed health check revokes readiness and a restart restores it', () async {
    var running = true;
    final cups = CupsIos.forTest(invoke: (method, arguments) async {
      if (!running) throw PlatformException(code: 'unavailable');
      return method == 'discover'
          ? 'direct gutenprint53+usb://dnp-ds620/123 "DNP"'
          : {'port': 16311};
    });
    expect(await cups.initialize(), true);
    running = false;
    expect(await cups.initialize(), false);
    expect(cups.ready, false);
    running = true;
    expect(await cups.initialize(), true);
    cups.dispose();
  });

  const rx = 'direct gutenprint53+usb://dnp-dsrx1/RX%201 "DNP" "RX1HS"';
  test(
    'permission denial leaves printing dormant and allows a later retry',
    () async {
      var allowed = false;
      final calls = <String>[];
      final cups = CupsIos.forTest(
        invoke: (method, arguments) async {
          calls.add(method);
          if (method == 'discover') {
            if (!allowed) throw PlatformException(code: 'unavailable');
            return rx;
          }
          expect(arguments!['driver'], 'dnp-dsrx1');
          expect(arguments['uri'], 'gutenprint53+usb://dnp-dsrx1/RX%201');
          return {'port': 16311};
        },
      );
      expect(await cups.initialize(), false);
      expect(cups.ready, false);
      expect(calls, ['discover']);
      allowed = true;
      expect(await cups.initialize(), true);
      expect(cups.ready, true);
      expect(cups.queueName, startsWith('dnp-dsrx1_'));
      cups.dispose();
    },
  );

  test(
    'no printer, unknown driver, and malformed output never start CUPS',
    () async {
      for (final output in [
        '',
        'direct usb://printer/a',
        'direct gutenprint53+usb://unknown/123',
        'direct gutenprint53+usb://dnp-ds620/',
        'direct gutenprint53+usb://dnp-ds620/123?test=1',
      ]) {
        final cups = CupsIos.forTest(
          invoke: (method, arguments) async {
            expect(method, 'discover');
            return output;
          },
        );
        expect(await cups.initialize(), false);
        expect(cups.ready, false);
        cups.dispose();
      }
    },
  );

  test('overlapping attempts run one discovery and one start', () async {
    final discovery = Completer<String>();
    var starts = 0;
    final cups = CupsIos.forTest(
      invoke: (method, arguments) async {
        if (method == 'discover') return discovery.future;
        starts++;
        return {'port': 16311};
      },
    );
    final first = cups.initialize();
    final second = cups.initialize();
    discovery.complete(rx);
    expect(await first, true);
    expect(await second, true);
    expect(starts, 1);
    cups.dispose();
  });

  test('daemon or queue setup failure never enables printing', () async {
    for (final response in [
      null,
      {},
      {'port': 0},
      {'port': 70000},
      {'port': '631'},
    ]) {
      final cups = CupsIos.forTest(
        invoke: (method, arguments) async =>
            method == 'discover' ? rx : response,
      );
      expect(await cups.initialize(), false);
      expect(cups.port, null);
      expect(cups.queueName, null);
      cups.dispose();
    }
  });

  test('model and serial select distinct queues without changing USB URIs', () {
    final printers = CupsIos.parseDiscovery(
      '$rx\n'
      'direct gutenprint53+usb://dnp-ds620/AB-CD "DNP"\n'
      'direct gutenprint53+usb://dnp-ds620/AB_CD "DNP"',
    );
    expect(printers.length, 3);
    expect(printers.map((p) => p['queueName']).toSet().length, 3);
    expect(printers[1]['driver'], 'dnp-ds620');
  });
}
