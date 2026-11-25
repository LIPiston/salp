import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/serial_profile.dart';

void main() {
  test('serial profiles survive reopen and stay out of sync records', () async {
    final dir = await Directory.systemTemp.createTemp('salp-serial-profile-');
    try {
      final repo = Repository(dir, Uint8List(32));
      const profile = SerialSettings('/dev/ttyUSB0', 9600, 7, 2, 2, 1);
      await repo.saveSerialProfile('router', profile, repo.epoch);
      final reopened = Repository(dir, Uint8List(32));
      await reopened.load();
      final saved = SerialSettings.fromJson(reopened.serialProfiles['router']!);
      expect(
        [
          saved.path,
          saved.baud,
          saved.bits,
          saved.stopBits,
          saved.parity,
          saved.flow,
        ],
        ['/dev/ttyUSB0', 9600, 7, 2, 2, 1],
      );
      expect(reopened.syncEntries(), isEmpty);
      await expectLater(
        repo.saveSerialProfile(
          'invalid',
          const SerialSettings('bad\x00path', 9600, 8, 1, 0, 0),
          repo.epoch,
        ),
        throwsFormatException,
      );
      repo.epoch++;
      await expectLater(
        repo.saveSerialProfile('stale', profile, repo.epoch - 1),
        throwsStateError,
      );
      expect(repo.serialProfiles.keys, ['router']);
      await repo.removeSerialProfile('router', repo.epoch);
      await reopened.load();
      expect(reopened.serialProfiles, isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
