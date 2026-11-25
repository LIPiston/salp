import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/local_commit.dart';

void main() {
  test(
    'completed download cannot overwrite a file created just before commit',
    () async {
      final dir = await Directory.systemTemp.createTemp('salp-commit-');
      try {
        final source = File('${dir.path}/part')
          ..writeAsStringSync('downloaded');
        final target = File('${dir.path}/target')..writeAsStringSync('keep-me');
        await expectLater(
          commitNoReplace(source, target),
          throwsA(isA<FileSystemException>()),
        );
        expect(await target.readAsString(), 'keep-me');
        expect(await source.readAsString(), 'downloaded');
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'commit publishes completed bytes and removes only its own staging file',
    () async {
      final dir = await Directory.systemTemp.createTemp('salp-commit-');
      try {
        final source = File('${dir.path}/part')..writeAsStringSync('complete');
        final target = File('${dir.path}/中文.bin');
        await commitNoReplace(source, target);
        expect(await target.readAsString(), 'complete');
        expect(await source.exists(), false);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
