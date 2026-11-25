import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/sync.dart';
import 'package:salp/core/sync_service.dart';
import 'package:salp/core/master_password.dart';

void main() {
  test(
    'sync backup restore is local, authenticated, atomic and undoable',
    () async {
      final dir = await Directory.systemTemp.createTemp('salp-sync-restore-');
      try {
        final repo = Repository(dir, Uint8List(32));
        repo.masterPassword = await MasterPassword.create('restore-password');
        repo.snippets['current'] = 'current secret';
        repo.syncBase = {'snippet:base': 'server-known'};
        repo.syncEndpoint = 'https://dav.invalid/vault';
        repo.knownHosts['example:22'] = 'pinned-key';
        repo.mcpAgents.add({'id': 'agent-kept'});
        repo.syncBackup = {
          'local': {'snippet:old': 'old secret'},
          'remote': {'snippet:remote': 'remote secret'},
        };
        await repo.save();
        final current = repo.syncEntries(), backup = repo.syncBackup;
        Future<void> restore(String password) => repo.restoreSyncBackup(
          version: 'local',
          password: password,
          authority: repo.epoch,
          expectedEntries: current,
          expectedBackup: backup,
        );
        await expectLater(restore('wrong-password'), throwsStateError);
        expect(repo.snippets, {'current': 'current secret'});
        await restore('restore-password');
        expect(repo.snippets, {'old': 'old secret'});
        expect(repo.syncBackup['undo'], current);
        expect(repo.syncBase, {'snippet:base': 'server-known'});
        expect(repo.syncEndpoint, 'https://dav.invalid/vault');
        expect(repo.knownHosts, {'example:22': 'pinned-key'});
        expect(repo.mcpAgents.single['id'], 'agent-kept');
        final reopened = Repository(dir, Uint8List(32));
        await reopened.load();
        expect(reopened.snippets, {'old': 'old secret'});
        final disk = String.fromCharCodes(
          await File('${dir.path}/vault.salp').readAsBytes(),
        );
        expect(disk, isNot(contains('old secret')));
        expect(disk, isNot(contains('current secret')));
        await reopened.restoreSyncBackup(
          version: 'undo',
          password: 'restore-password',
          authority: reopened.epoch,
          expectedEntries: reopened.syncEntries(),
          expectedBackup: reopened.syncBackup,
        );
        expect(reopened.snippets, {'current': 'current secret'});
        await expectLater(
          restore('restore-password'),
          throwsStateError,
          reason: 'preview cannot replace a later committed change',
        );
        final latest = repo.syncEntries(), latestBackup = repo.syncBackup;
        repo.epoch++;
        await expectLater(
          repo.restoreSyncBackup(
            version: 'remote',
            password: 'restore-password',
            authority: repo.epoch - 1,
            expectedEntries: latest,
            expectedBackup: latestBackup,
          ),
          throwsStateError,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test('sync applies validated data with credentials and retains an encrypted conflict backup', () async {
    final dir = await Directory.systemTemp.createTemp('salp-sync-repo-');
    try {
      final repo = Repository(dir, Uint8List(32));
      await repo.upsert(
        Host(id: 'one', name: 'local', address: 'local.test'),
        const Credential(password: 'secret-local'),
      );
      final before = repo.syncEntries();
      final remote = {
        'host:one': {
          'host': Host(
            id: 'one',
            name: 'remote',
            address: 'remote.test',
          ).toJson(),
          'credential': const Credential(password: 'secret-remote').toJson(),
        },
      };
      await repo.applySync(
        remote,
        base: remote,
        endpoint: 'https://dav.test/vault',
        backup: {'local': before, 'remote': remote},
        authority: repo.epoch,
      );
      final reopened = Repository(dir, Uint8List(32));
      await reopened.load();
      expect(reopened.hosts.single.name, 'remote');
      expect(reopened.credentials['one']!.password, 'secret-remote');
      expect(reopened.syncBackup['local'], before);
      expect(reopened.syncBase, remote);
      final disk = String.fromCharCodes(
        await File('${dir.path}/vault.salp').readAsBytes(),
      );
      expect(disk.contains('secret-local'), false);
      expect(disk.contains('secret-remote'), false);
      await expectLater(
        repo.applySync(
          {
            'host:bad': {
              'host': {'id': 'bad'},
            },
          },
          base: {},
          endpoint: '',
          backup: {},
          authority: repo.epoch,
        ),
        throwsA(anything),
      );
      expect(repo.hosts.single.name, 'remote');
      repo.epoch++;
      await expectLater(
        repo.applySync(
          before,
          base: {},
          endpoint: '',
          backup: {},
          authority: repo.epoch - 1,
        ),
        throwsStateError,
      );
      expect(repo.hosts.single.name, 'remote');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('sync excludes concurrent password changes and rejects stale password previews', () async {
    final dir = await Directory.systemTemp.createTemp('salp-sync-concurrent-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entered = Completer<void>(), release = Completer<void>();
    var gets = 0;
    server.listen((request) async {
      if (request.method == 'GET' && gets++ == 0) {
        entered.complete();
        await release.future;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });
    final client = WebDavClient(
      Uri.parse('http://127.0.0.1:${server.port}/vault'),
      '',
      '',
    );
    try {
      final repo = Repository(dir, Uint8List(32));
      repo.masterPassword = await MasterPassword.create('original-password');
      await repo.save();
      final service = SyncService(repo, client);
      final pending = service.prepare('original-password');
      await entered.future;
      await expectLater(
        changeMasterPassword(repo, 'original-password', 'changed-password'),
        throwsStateError,
      );
      release.complete();
      final prepared = await pending;
      await changeMasterPassword(repo, 'original-password', 'changed-password');
      await expectLater(
        service.commit(prepared, {}),
        throwsStateError,
        reason: 'an old preview must not upload with the previous password',
      );
      expect(repo.syncBackup, isEmpty);
      expect(
        await MasterPassword.verify('changed-password', repo.masterPassword!),
        true,
      );
      prepared.forget();
    } finally {
      if (!release.isCompleted) release.complete();
      client.close();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });

  test('two actual clients sync independent edits and keep delete/edit conflicts until selected', () async {
    final dir = await Directory.systemTemp.createTemp('salp-sync-clients-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final objects = <String, Uint8List>{};
    final revisions = <String, int>{};
    server.listen((request) async {
      final path = request.uri.path;
      final content = objects[path];
      final revision = revisions[path] ?? 0;
      if (request.method == 'GET') {
        request.response.statusCode = content == null ? 404 : 200;
        if (content != null) {
          request.response.headers.set('etag', '"$revision"');
          request.response.add(content);
        }
      } else if (request.method == 'DELETE') {
        objects.remove(path);
        request.response.statusCode = 204;
      } else {
        final match = request.headers.value('if-match');
        final none = request.headers.value('if-none-match');
        if ((none == '*' && content != null) ||
            (match != null && match != '"$revision"')) {
          request.response.statusCode = 412;
        } else {
          objects[path] = Uint8List.fromList(
            await request.fold<List<int>>([], (a, b) => a..addAll(b)),
          );
          revisions[path] = revision + 1;
          request.response.statusCode = 201;
          request.response.headers.set('etag', '"${revision + 1}"');
        }
      }
      await request.response.close();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/vault');
    final ca = WebDavClient(uri, 'u', 'p'), cb = WebDavClient(uri, 'u', 'p');
    try {
      final a = Repository(
        await Directory('${dir.path}/a').create(),
        Uint8List(32),
      );
      final b = Repository(
        await Directory('${dir.path}/b').create(),
        Uint8List(32),
      );
      a.masterPassword = await MasterPassword.create('master-password');
      b.masterPassword = await MasterPassword.create('master-password');
      a.webDav = {'url': uri.toString(), 'username': 'u', 'password': 'p'};
      b.webDav = {...a.webDav};
      final sa = SyncService(a, ca), sb = SyncService(b, cb);
      a.snippets['shared'] = 'original';
      await sa.commit(await sa.prepare('master-password'), {});
      await sb.commit(await sb.prepare('master-password'), {});
      expect(b.snippets['shared'], 'original');
      a.snippets['left'] = 'one';
      b.snippets['right'] = 'two';
      await sa.commit(await sa.prepare('master-password'), {});
      await sb.commit(await sb.prepare('master-password'), {});
      expect(b.snippets, {'shared': 'original', 'left': 'one', 'right': 'two'});
      a.snippets.remove('shared');
      await sa.commit(await sa.prepare('master-password'), {});
      b.snippets['shared'] = 'edited';
      final conflict = await sb.prepare('master-password');
      expect(conflict.merge.conflicts.single.key, 'snippet:shared');
      expect(b.snippets['shared'], 'edited');
      await expectLater(sb.commit(conflict, {}), throwsStateError);
      await sb.commit(conflict, {'snippet:shared': SyncChoice.local});
      expect(b.snippets['shared'], 'edited');
      final stale = await sb.prepare('master-password');
      b.epoch += 2;
      await expectLater(sb.commit(stale, {}), throwsStateError);
      await expectLater(
        sb.prepare('wrong-password'),
        throwsA(isA<SyncException>()),
      );
      expect(b.snippets['shared'], 'edited');
      await changeMasterPassword(a, 'master-password', 'new-master-password');
      expect(
        await MasterPassword.verify('new-master-password', a.masterPassword!),
        true,
      );
      await expectLater(
        sb.prepare('master-password'),
        throwsA(isA<SyncException>()),
      );
      final adoption = await sb.prepare(
        'new-master-password',
        localPassword: 'master-password',
      );
      await sb.commit(adoption, {});
      expect(
        await MasterPassword.verify('new-master-password', b.masterPassword!),
        true,
      );
      expect(b.snippets['shared'], 'edited');
    } finally {
      ca.close();
      cb.close();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });

  test(
    'encrypted repository survives reopen without plaintext credentials',
    () async {
      final dir = await Directory.systemTemp.createTemp('salp-repo-test-');
      try {
        final repo = Repository(dir, Uint8List(32));
        await repo.upsert(
          Host(id: 'one', name: '生产', address: 'example.test'),
          const Credential(password: 'never-plaintext-123'),
        );
        expect(
          String.fromCharCodes(
            await File('${dir.path}/vault.salp').readAsBytes(),
          ).contains('never-plaintext-123'),
          false,
        );
        final reopened = Repository(dir, Uint8List(32));
        await reopened.load();
        expect(reopened.hosts.single.name, '生产');
        expect(reopened.credentials['one']!.password, 'never-plaintext-123');
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
