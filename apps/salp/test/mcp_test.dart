import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/connection.dart';
import 'package:salp/core/mcp.dart';
import 'package:salp/core/session_log.dart';

void main() {
  test('MCP refuses actions after its active audit file is removed', () async {
    final dir = await Directory.systemTemp.createTemp(
      'salp-mcp-audit-removed-',
    );
    final repo = Repository(dir, Uint8List(32));
    repo.hosts.add(
      Host(id: 'allowed', name: 'fixture', address: 'fixture.invalid'),
    );
    final agent = McpAgent.create('fixture', ['allowed'], mode: McpMode.yolo);
    repo.mcpAgents.add(agent.toJson());
    var opened = 0;
    final server = McpServer(
      repo,
      approve: (_) async => false,
      openSession: (h, t) async {
        opened++;
        return TerminalSession(t, host: h);
      },
    );
    final http = HttpClient();
    try {
      await server.start();
      final file = (await Directory(
        '${dir.path}/mcp-audit',
      ).list().toList()).single;
      await file.delete();
      final request = await http.postUrl(Uri.parse(server.url));
      request.headers.set('authorization', 'Bearer ${agent.token}');
      request.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {
            'name': 'terminal_open',
            'arguments': {'hostId': 'allowed'},
          },
        }),
      );
      final result = jsonDecode(
        await utf8.decoder.bind(await request.close()).join(),
      ) as Map;
      expect(result['error'], isNotNull);
      expect(opened, 0);
    } finally {
      http.close(force: true);
      await server.close();
      await dir.delete(recursive: true);
    }
  });

  test('MCP network listening requires confirmation and exact Host/Origin allowlists', () async {
    final dir = await Directory.systemTemp.createTemp('salp-mcp-bind-');
    final repo = Repository(dir, Uint8List(32));
    final agent = McpAgent.create('fixture', [], mode: McpMode.yolo);
    repo.mcpAgents.add(agent.toJson());
    final server = McpServer(
      repo,
      approve: (_) async => false,
      openSession: (h, t) async => TerminalSession(t, host: h),
    );
    final http = HttpClient();
    try {
      await expectLater(
        server.start(address: '0.0.0.0', allowedHosts: ['127.0.0.1']),
        throwsStateError,
      );
      expect(server.running, false);
      await expectLater(
        server.start(address: '0.0.0.0', confirmedNonLoopback: true),
        throwsFormatException,
      );
      await server.start(
        address: '0.0.0.0',
        allowedHosts: ['127.0.0.1'],
        allowedOrigins: ['https://agent.example'],
        confirmedNonLoopback: true,
      );
      Future<int> call({
        String? host,
        String? origin,
        bool token = true,
      }) async {
        final request = await http.postUrl(Uri.parse(server.url));
        if (host != null) request.headers.set('host', host);
        if (origin != null) request.headers.set('origin', origin);
        if (token) {
          request.headers.set('authorization', 'Bearer ${agent.token}');
        }
        request.write(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        );
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await call(), 200);
      expect(await call(token: false), 401);
      expect(await call(host: 'attacker.example'), 403);
      expect(await call(host: '127.0.0.1:1'), 403);
      expect(await call(origin: 'https://agent.example.evil'), 403);
      expect(await call(origin: 'null'), 403);
      expect(await call(origin: 'https://agent.example'), 200);
      await server.close();
      await server.start();
      expect(
        await call(origin: 'https://agent.example'),
        403,
        reason: 'allowlists from a previous run must not persist',
      );
    } finally {
      http.close(force: true);
      await server.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'MCP audit capacity blocks subsequent actions and restart opens a new log',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'salp-mcp-audit-limit-',
      );
      final repo = Repository(dir, Uint8List(32));
      repo.hosts.add(
        Host(id: 'allowed', name: 'fixture', address: 'fixture.invalid'),
      );
      final agent = McpAgent.create('fixture', ['allowed'], mode: McpMode.yolo);
      repo.mcpAgents.add(agent.toJson());
      var opened = 0;
      final server = McpServer(
        repo,
        approve: (_) async => false,
        openSession: (h, t) async {
          opened++;
          return TerminalSession(t, host: h);
        },
      );
      final http = HttpClient();
      Future<Map> call(String name, Map<String, dynamic> args) async {
        final request = await http.postUrl(Uri.parse(server.url));
        request.headers.set('authorization', 'Bearer ${agent.token}');
        request.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {'name': name, 'arguments': args},
          }),
        );
        return jsonDecode(await utf8.decoder.bind(await request.close()).join())
            as Map;
      }

      try {
        await server.start();
        var blocked = false;
        for (var i = 0; i < 2500; i++) {
          if ((await call('hosts_list', {}))['error'] != null) {
            blocked = true;
            break;
          }
        }
        expect(blocked, true);
        expect(
          (await call('terminal_open', {'hostId': 'allowed'}))['error'],
          isNotNull,
        );
        expect(opened, 0);
        await server.close();
        final file =
            (await Directory('${dir.path}/mcp-audit').list().toList()).single
                as File;
        expect(await file.length(), lessThanOrEqualTo(1024 * 1024));
        expect(await SessionLog.read(file, repo.key), isNotEmpty);
        await server.start();
        expect(
          (await call('terminal_open', {'hostId': 'allowed'}))['error'],
          isNull,
        );
        expect(opened, 1);
      } finally {
        http.close(force: true);
        await server.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'MCP stop cancels a pending start and prevents a late listener',
    () async {
      final dir = await Directory.systemTemp.createTemp('salp-mcp-start-');
      final repo = Repository(dir, Uint8List(32));
      final server = McpServer(
        repo,
        approve: (_) async => false,
        openSession: (h, t) async => TerminalSession(t, host: h),
      );
      try {
        final starting = expectLater(server.start(), throwsStateError);
        await server.close();
        await starting;
        expect(server.running, false);
      } finally {
        await server.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('a stopped MCP request cannot append into the next audit log', () async {
    final dir = await Directory.systemTemp.createTemp('salp-mcp-audit-');
    final repo = Repository(dir, Uint8List(32));
    repo.hosts.add(
      Host(id: 'allowed', name: 'allowed', address: 'fixture.invalid'),
    );
    final agent = McpAgent.create('fixture', ['allowed']);
    repo.mcpAgents.add(agent.toJson());
    final entered = Completer<void>(), decision = Completer<bool>();
    final server = McpServer(
      repo,
      approve: (_) {
        entered.complete();
        return decision.future;
      },
      openSession: (h, t) async => TerminalSession(t, host: h),
    );
    final http = HttpClient();
    final logs = Directory('${dir.path}/mcp-audit');
    try {
      await server.start();
      final firstFile = (await logs.list().toList()).single.path;
      final request = await http.postUrl(Uri.parse(server.url));
      request.headers.set('authorization', 'Bearer ${agent.token}');
      request.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {
            'name': 'terminal_open',
            'arguments': {'hostId': 'allowed'},
          },
        }),
      );
      final response = request.close().then<void>((r) async {
        await r.drain<void>();
      }, onError: (Object _) {});
      await entered.future;
      await server.close();
      await server.start();
      decision.complete(true);
      await response;
      // Flush the old approval continuation and HTTP error response.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await server.close();
      final secondFile = (await logs.list().toList()).singleWhere(
        (f) => f.path != firstFile,
      );
      final rows = await SessionLog.read(File(secondFile.path), repo.key);
      expect(
        rows,
        isEmpty,
        reason: 'old requests belong to their original run',
      );
    } finally {
      if (!decision.isCompleted) decision.complete(false);
      http.close(force: true);
      await server.close();
      await dir.delete(recursive: true);
    }
  });

  test('MCP reserves session capacity before concurrent opens await transport', () async {
    final dir = await Directory.systemTemp.createTemp('salp-mcp-capacity-');
    final repo = Repository(dir, Uint8List(32));
    repo.hosts.add(
      Host(id: 'allowed', name: 'allowed', address: 'fixture.invalid'),
    );
    final agent = McpAgent.create('fixture', ['allowed'], mode: McpMode.yolo);
    repo.mcpAgents.add(agent.toJson());
    final pending = Completer<void>(), started = Completer<void>();
    var opened = 0;
    final server = McpServer(
      repo,
      approve: (_) async => false,
      openSession: (host, title) async {
        opened++;
        if (opened >= 16) {
          if (!started.isCompleted) started.complete();
          await pending.future;
        }
        return TerminalSession(title, host: host);
      },
    );
    final http = HttpClient();
    try {
      await server.start();
      Future<Map<String, dynamic>> open() async {
        final request = await http.postUrl(Uri.parse(server.url));
        request.headers.set('authorization', 'Bearer ${agent.token}');
        request.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'terminal_open',
              'arguments': {'hostId': 'allowed'},
            },
          }),
        );
        final response = await request.close();
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      for (var i = 0; i < 15; i++) {
        expect((await open())['error'], isNull);
      }
      final first = open();
      await started.future;
      final second = open();
      // Let the second HTTP request enter while the first transport is blocked.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      pending.complete();
      final results = await Future.wait([first, second]);
      expect(opened, 16);
      expect(results.where((r) => r['error'] != null), hasLength(1));
    } finally {
      if (!pending.isCompleted) pending.complete();
      http.close(force: true);
      await server.close();
      await dir.delete(recursive: true);
    }
  });

  test('MCP enforces auth, host/origin, scope, approvals and lock continuity over HTTP', () async {
    final dir = await Directory.systemTemp.createTemp('salp-mcp-');
    final repo = Repository(dir, Uint8List(32));
    repo.hosts.add(
      Host(id: 'allowed', name: 'Only Host', address: 'example.test'),
    );
    repo.hosts.add(
      Host(id: 'hidden', name: 'Secret Host', address: 'private.test'),
    );
    final agent = McpAgent.create('Test Agent', ['allowed']);
    repo.mcpAgents.add(agent.toJson());
    final approval = Completer<bool>();
    var opened = 0;
    final server = McpServer(
      repo,
      approve: (_) => approval.future,
      openSession: (host, label) async {
        opened++;
        return TerminalSession(label, host: host);
      },
    );
    await server.start();
    final client = HttpClient();
    Future<(int, Map<String, dynamic>)> call(
      String tool,
      Map<String, dynamic> arguments, {
      bool authenticated = true,
      bool duplicateAuth = false,
      String? origin,
      String? host,
    }) async {
      final request = await client.postUrl(Uri.parse(server.url));
      request.headers.contentType = ContentType.json;
      if (authenticated) {
        request.headers.set('authorization', 'Bearer ${agent.token}');
        if (duplicateAuth) {
          request.headers.add('authorization', 'Bearer forged-token');
        }
      }
      if (origin != null) request.headers.set('origin', origin);
      if (host != null) request.headers.set('host', host);
      request.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': tool, 'arguments': arguments},
        }),
      );
      final response = await request.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>,
      );
    }

    try {
      expect((await call('hosts_list', {}, authenticated: false)).$1, 401);
      expect(
        (await call(
          'hosts_list',
          {},
          duplicateAuth: true,
        ).timeout(const Duration(seconds: 2))).$1,
        401,
      );
      expect(
        (await call('hosts_list', {}, origin: 'https://evil.test')).$1,
        403,
      );
      expect((await call('hosts_list', {}, host: 'evil.test')).$1, 403);
      final list = await call('hosts_list', {});
      expect(list.$1, 200);
      expect(jsonEncode(list.$2), contains('Only Host'));
      expect(jsonEncode(list.$2), isNot(contains('Secret Host')));
      final forbidden = await call('terminal_open', {'hostId': 'hidden'});
      expect(jsonEncode(forbidden.$2), contains('范围'));
      expect(opened, 0);
      final pending = call('terminal_open', {'hostId': 'allowed'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      repo.locked = true;
      repo.epoch++;
      approval.complete(true);
      final invalid = await pending;
      expect(jsonEncode(invalid.$2), contains('需要解锁 salp'));
      expect(opened, 0);
      expect(
        jsonEncode((await call('hosts_list', {})).$2),
        contains('需要解锁 salp'),
      );
      repo.locked = false;
      repo.epoch++;
      repo.mcpAgents.clear();
      expect((await call('hosts_list', {})).$1, 401);
    } finally {
      client.close(force: true);
      await server.close();
      await dir.delete(recursive: true);
    }
  });
}
