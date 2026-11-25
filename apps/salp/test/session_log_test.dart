import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/session_log.dart';

void main() {
  test('retention removes only expired salp logs', () async {
    final dir = await Directory.systemTemp.createTemp('salp-log-retention-');
    try {
      final old = File('${dir.path}/old.salp-log');
      final other = File('${dir.path}/notes.txt');
      await old.writeAsString('old');
      await other.writeAsString('keep');
      final past = DateTime.now().subtract(const Duration(days: 8));
      await old.setLastModified(past);
      await other.setLastModified(past);
      await SessionLog.prune(dir);
      expect(await old.exists(), false);
      expect(await other.exists(), true);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'session log encrypts timestamped output and has a bounded size',
    () async {
      final dir = await Directory.systemTemp.createTemp('salp-log-');
      try {
        final key = Uint8List(32);
        final log = await SessionLog.start(dir, key, maxBytes: 256);
        log.append('secret terminal output');
        log.append('中文\r\n');
        await log.close();
        final raw = await log.file.readAsBytes();
        expect(
          String.fromCharCodes(raw).contains('secret terminal output'),
          false,
        );
        final rows = await SessionLog.read(log.file, key);
        expect(
          rows.map((e) => e['text']).join(),
          'secret terminal output中文\r\n',
        );
        expect(DateTime.tryParse(rows.first['at'] as String), isNotNull);
        final limited = await SessionLog.start(dir, key, maxBytes: 128);
        expect(limited.append('x' * 1000), false);
        expect(limited.limited, true);
        await limited.close();
        expect(await limited.file.length(), lessThanOrEqualTo(128));
        final corrupt = await log.file.open(mode: FileMode.append);
        await corrupt.writeFrom([0, 0, 0, 10, 1, 2]);
        await corrupt.close();
        await expectLater(
          SessionLog.read(log.file, key),
          throwsFormatException,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
