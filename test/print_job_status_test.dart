import 'package:flutter_test/flutter_test.dart';
import 'package:printing_ffi/printing_ffi.dart';

void main() {
  test('Android and desktop CUPS share the full IPP job lifecycle', () {
    final states = {
      3: PrintJobStatus.pending,
      4: PrintJobStatus.held,
      5: PrintJobStatus.processing,
      6: PrintJobStatus.stopped,
      7: PrintJobStatus.canceled,
      8: PrintJobStatus.aborted,
      9: PrintJobStatus.completed,
    };
    for (final entry in states.entries) {
      expect(PrintJobStatus.fromIpp(entry.key), entry.value);
    }
    expect(PrintJobStatus.fromIpp(999), PrintJobStatus.unknown);
  });

  test('Windows errors retain priority over completion flags', () {
    expect(PrintJobStatus.fromWindows(4096 | 2), PrintJobStatus.error);
    expect(PrintJobStatus.fromWindows(4096 | 128), PrintJobStatus.completed);
  });
}
