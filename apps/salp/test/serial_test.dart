import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/serial.dart';

void main() {
  test('serial settings reject unsafe values before opening a device', () {
    expect(
      () => SerialConnection.open('/never/existing', baud: 0),
      throwsFormatException,
    );
    expect(
      () => SerialConnection.open('/never/existing', bits: 4),
      throwsFormatException,
    );
  });
  test('system serial enumeration and missing device fail cleanly', () {
    expect(SerialConnection.listPorts(), isA<List<String>>());
    expect(
      () => SerialConnection.open('/dev/salp-nonexistent-fixture'),
      throwsA(isA<SerialException>()),
    );
  }, skip: !Platform.isLinux);
}
