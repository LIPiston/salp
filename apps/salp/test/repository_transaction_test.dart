import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/repository.dart';

void main() {
  late Directory dir;
  late Repository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('salp-repo-transaction-');
    repo = Repository(dir, Uint8List(32));
  });
  tearDown(() => dir.delete(recursive: true));

  test('overlapping failed edits leave no host or credential and later writes recover', () async {
    // Two real filesystem failures, including edits of the same host. A rollback
    // to the other uncommitted edit must never become visible or be saved later.
    final obstacle = await Directory('${dir.path}/vault.pending').create();
    final first = repo.upsert(
      Host(id: 'one', name: 'failed-first', address: 'first.test'),
      const Credential(password: 'first-secret'),
    );
    final failedFirst = expectLater(first, throwsA(isA<FileSystemException>()));
    final second = repo.upsert(
      Host(id: 'one', name: 'failed-second', address: 'second.test'),
      const Credential(password: 'second-secret'),
    );
    final failedSecond = expectLater(
      second,
      throwsA(isA<FileSystemException>()),
    );
    await Future.wait([failedFirst, failedSecond]);
    expect(repo.hosts, isEmpty);
    expect(repo.credentials, isEmpty);
    await obstacle.delete();
    await repo.upsert(
      Host(id: 'kept', name: 'kept', address: 'kept.test'),
      const Credential(password: 'kept-secret'),
    );
    final reopened = Repository(dir, Uint8List(32));
    await reopened.load();
    expect(reopened.hosts.map((h) => h.id), ['kept']);
    expect(reopened.credentials.keys, ['kept']);
    expect(repo.syncEntries(), reopened.syncEntries());
  });

  test('readers only see a host after the encrypted write commits', () async {
    final write = repo.upsert(
      Host(id: 'one', name: 'one', address: 'one.test'),
      const Credential(password: 'secret'),
    );
    final visibleBeforeCommit = repo.hosts.length;
    final credentialsBeforeCommit = repo.credentials.length;
    await write;
    expect(visibleBeforeCommit, 0);
    expect(credentialsBeforeCommit, 0);
    expect(repo.hosts.single.id, 'one');
  });

  test(
    'locking invalidates a queued host save without changing disk',
    () async {
      await repo.upsert(
        Host(id: 'old', name: 'old', address: 'old.test'),
        const Credential(),
      );
      final write = repo.upsert(
        Host(id: 'new', name: 'new', address: 'new.test'),
        const Credential(),
      );
      repo.locked = true;
      repo.epoch++;
      await expectLater(write, throwsStateError);
      final reopened = Repository(dir, Uint8List(32));
      await reopened.load();
      expect(reopened.hosts.map((h) => h.id), ['old']);
      expect(repo.syncEntries(), reopened.syncEntries());
    },
  );
}
