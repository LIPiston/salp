import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/master_password.dart';
import 'package:salp/core/repository.dart';

void main() {
  test('disabling startup authentication requires the current password and persists after reopen', () async {
    final dir = await Directory.systemTemp.createTemp('salp-security-');
    try {
      final repo = Repository(dir, Uint8List(32));
      repo.masterPassword = await MasterPassword.create('current-password');
      await repo.setStartupAuthentication(true, 'current-password', repo.epoch);
      expect(repo.startupAuthentication, true);
      await expectLater(
        repo.setStartupAuthentication(false, 'wrong-password', repo.epoch),
        throwsStateError,
      );
      expect(repo.startupAuthentication, true);
      final epoch = repo.epoch;
      repo.epoch += 2;
      await expectLater(
        repo.setStartupAuthentication(false, 'current-password', epoch),
        throwsStateError,
      );
      expect(repo.startupAuthentication, true);
      await repo.setStartupAuthentication(
        false,
        'current-password',
        repo.epoch,
      );
      final reopened = Repository(dir, Uint8List(32));
      await reopened.load();
      expect(reopened.startupAuthentication, false);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
