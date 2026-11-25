import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/sync.dart';

void main() {
  test('conditional-write capability rejects a server that ignores preconditions without touching vault', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final objects = <String, List<int>>{
      '/vault': [9, 8, 7],
    };
    server.listen((request) async {
      if (request.method == 'PUT') {
        objects[request.uri.path] = await request.fold<List<int>>(
          [],
          (a, b) => a..addAll(b),
        );
        request.response.statusCode = 201;
        request.response.headers.set('etag', '"1"');
      } else if (request.method == 'DELETE') {
        objects.remove(request.uri.path);
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
    final client = WebDavClient(
      Uri.parse('http://127.0.0.1:${server.port}/vault'),
      'u',
      'p',
    );
    try {
      await expectLater(
        client.verifyConditionalWrites(),
        throwsA(isA<SyncException>()),
      );
      expect(objects, {
        '/vault': [9, 8, 7],
      });
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test(
    'independent edits merge while edit/delete and concurrent edits survive',
    () {
      final plan = SyncMerge(
        base: {
          'a': {'name': 'old'},
          'b': 'old',
          'deleted': 'old',
        },
        local: {
          'a': {'name': 'local'},
          'b': 'old',
          'local-only': 'one',
        },
        remote: {
          'a': {'name': 'remote'},
          'b': 'remote',
          'deleted': 'edited',
          'remote-only': 'two',
        },
      );
      expect(plan.merged['b'], 'remote');
      expect(plan.merged['local-only'], 'one');
      expect(plan.merged['remote-only'], 'two');
      expect(plan.conflicts.map((c) => c.key).toSet(), {'a', 'deleted'});
      final deletion = plan.conflicts.singleWhere((c) => c.key == 'deleted');
      expect(deletion.local, isNull);
      expect(deletion.remote, 'edited');
      expect(() => plan.resolve({}), throwsStateError);
      final resolved = plan.resolve({
        'a': SyncChoice.remote,
        'deleted': SyncChoice.local,
      });
      expect(resolved['a'], {'name': 'remote'});
      expect(resolved.containsKey('deleted'), false);
    },
  );

  test('sync envelope keeps credentials encrypted and authenticates password and corruption', () async {
    const content = {
      'host:a': {'password': 'secret-never-in-clear'},
    };
    final first = await SyncVault.create(content, 'master-password');
    expect(utf8.decode(first.bytes).contains('secret-never-in-clear'), false);
    final opened = await SyncVault.open(first.bytes, 'master-password');
    expect(opened.entries, content);
    await expectLater(
      SyncVault.open(first.bytes, 'wrong-password'),
      throwsA(anything),
    );
    final corrupted =
        jsonDecode(utf8.decode(first.bytes)) as Map<String, dynamic>;
    final payload = base64.decode(corrupted['payload'] as String);
    payload.last ^= 1;
    corrupted['payload'] = base64.encode(payload);
    await expectLater(
      SyncVault.open(
        Uint8List.fromList(utf8.encode(jsonEncode(corrupted))),
        'master-password',
      ),
      throwsA(anything),
    );
    final rewrapped = await opened.seal(content, 'new-password');
    final next = await SyncVault.open(rewrapped.bytes, 'new-password');
    expect(next.dataKey, opened.dataKey);
    await expectLater(
      SyncVault.open(rewrapped.bytes, 'master-password'),
      throwsA(anything),
    );
  });

  test('WebDAV uses conditional creation/replacement and preserves competing update', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Uint8List? stored;
    var revision = 0;
    final conditions = <String?>[];
    server.listen((request) async {
      final tag = '"$revision"';
      final match = request.headers.value(HttpHeaders.ifMatchHeader);
      final none = request.headers.value(HttpHeaders.ifNoneMatchHeader);
      if ((match != null && (stored == null || match != tag)) ||
          (none == '*' && stored != null)) {
        request.response.statusCode = 412;
      } else if (request.method == 'GET') {
        request.response.statusCode = stored == null ? 404 : 200;
        if (stored != null) {
          request.response.headers.set(HttpHeaders.etagHeader, tag);
          request.response.add(stored!);
        }
      } else if (request.method == 'PUT') {
        conditions.add(match ?? none);
        stored = Uint8List.fromList(
          await request.fold<List<int>>([], (a, b) => a..addAll(b)),
        );
        revision++;
        request.response.statusCode = 201;
        request.response.headers.set(HttpHeaders.etagHeader, '"$revision"');
      }
      await request.response.close();
    });
    final client = WebDavClient(
      Uri.parse('http://127.0.0.1:${server.port}/vault'),
      'user',
      'pass',
    );
    try {
      expect(await client.fetch(), isNull);
      await client.put(Uint8List.fromList([1, 2, 3]), etag: null);
      final first = (await client.fetch())!;
      expect(first.bytes, [1, 2, 3]);
      await client.put(Uint8List.fromList([4]), etag: first.etag);
      await expectLater(
        client.put(Uint8List.fromList([5]), etag: first.etag),
        throwsA(isA<SyncRemoteChanged>()),
      );
      expect((await client.fetch())!.bytes, [4]);
      expect(conditions, ['*', '"1"']);
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test(
    'WebDAV refuses redirects, weak ETags, server errors and oversized data',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var status = 302;
      var weak = false;
      var reached = false;
      server.listen((request) async {
        if (request.uri.path == '/leak') reached = true;
        request.response.statusCode = status;
        request.response.headers.set(HttpHeaders.locationHeader, '/leak');
        request.response.headers.set(
          HttpHeaders.etagHeader,
          weak ? 'W/"1"' : '"1"',
        );
        if (status == 200 && !weak) {
          request.response.add(Uint8List(WebDavClient.maxBytes + 1));
        }
        await request.response.close().catchError((Object _) {});
      });
      final client = WebDavClient(
        Uri.parse('http://127.0.0.1:${server.port}/vault'),
        'user',
        'pass',
      );
      try {
        await expectLater(client.fetch(), throwsA(isA<SyncException>()));
        expect(reached, false);
        status = 500;
        await expectLater(client.fetch(), throwsA(isA<SyncException>()));
        status = 200;
        weak = true;
        await expectLater(client.fetch(), throwsA(isA<SyncException>()));
        weak = false;
        await expectLater(client.fetch(), throwsA(isA<SyncException>()));
        expect(
          () => WebDavClient(Uri.parse('http://example.com/vault'), 'u', 'p'),
          throwsFormatException,
        );
      } finally {
        client.close();
        await server.close(force: true);
      }
    },
  );
}
