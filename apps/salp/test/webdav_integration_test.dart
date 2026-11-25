import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/master_password.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/sync.dart';
import 'package:salp/core/sync_service.dart';

void main() {
  final fixture = Platform.environment['SALP_WEBDAV_FIXTURE'];
  test('WsgiDAV real authentication, encrypted two-client sync, stale ETag and backup restore', () async {
    final uri = Uri.parse(
      'http://127.0.0.1:${Platform.environment['SALP_WEBDAV_PORT']}/vault.salp',
    );
    final wrong = WebDavClient(uri, 'fixture', 'wrong-password');
    final first = WebDavClient(uri, 'fixture', 'fixture-only-password');
    final second = WebDavClient(uri, 'fixture', 'fixture-only-password');
    try {
      await expectLater(wrong.fetch(), throwsA(isA<SyncException>()));
      await first.verifyConditionalWrites();
      final a = Repository(
        await Directory('$fixture/a').create(),
        Uint8List(32),
      );
      final b = Repository(
        await Directory('$fixture/b').create(),
        Uint8List(32),
      );
      a.masterPassword = await MasterPassword.create('fixture-master-password');
      b.masterPassword = Map.of(a.masterPassword!);
      a.snippets['shared'] = 'secret shared content';
      final sa = SyncService(a, first), sb = SyncService(b, second);
      await sa.commit(await sa.prepare('fixture-master-password'), {});
      await sb.commit(await sb.prepare('fixture-master-password'), {});
      expect(b.snippets['shared'], 'secret shared content');
      final remoteFile = File('$fixture/share/vault.salp');
      expect(
        latin1.decode(await remoteFile.readAsBytes()),
        isNot(contains('secret shared content')),
      );
      a.snippets['a'] = 'A';
      b.snippets['b'] = 'B';
      final pa = await sa.prepare('fixture-master-password');
      final pb = await sb.prepare('fixture-master-password');
      await sa.commit(pa, {});
      await expectLater(sb.commit(pb, {}), throwsA(isA<SyncRemoteChanged>()));
      expect(b.snippets, {'shared': 'secret shared content', 'b': 'B'});
      expect(b.syncBackup['local']['snippet:b'], 'B');
      await sb.commit(await sb.prepare('fixture-master-password'), {});
      expect(b.snippets, {
        'shared': 'secret shared content',
        'a': 'A',
        'b': 'B',
      });
      final beforeRestore = await remoteFile.readAsBytes();
      await b.restoreSyncBackup(
        version: 'local',
        password: 'fixture-master-password',
        authority: b.epoch,
        expectedEntries: b.syncEntries(),
        expectedBackup: b.syncBackup,
      );
      expect(b.snippets, {'shared': 'secret shared content', 'b': 'B'});
      expect(await remoteFile.readAsBytes(), beforeRestore);
      expect(
        (await Directory(
          '$fixture/share',
        ).list().toList()).map((f) => f.uri.pathSegments.last),
        ['vault.salp'],
      );
    } finally {
      wrong.close();
      first.close();
      second.close();
    }
  }, skip: fixture == null ? 'Run tool/verify_webdav.py' : false);
}
