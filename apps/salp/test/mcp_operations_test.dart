import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:salp/core/connection.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/mcp.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/session_log.dart';

void main() {
  final fixture = Platform.environment['SALP_SSH_FIXTURE'];
  test('MCP structured SSH commands and SFTP use exact approval, bounded output and no local path access', () async {
    final config =
        jsonDecode(await File('$fixture/public.json').readAsString()) as Map;
    final repo = Repository(
      Directory('$fixture/mcp-structured-vault'),
      Uint8List(32),
    );
    await repo.directory.create();
    final host = Host(
      id: 'remote',
      name: 'fixture',
      address: '127.0.0.1',
      port: config['port'] as int,
      username: config['username'] as String,
    );
    repo.hosts.add(host);
    repo.credentials[host.id] = Credential(
      privateKey: await File('$fixture/client_key').readAsString(),
    );
    repo.knownHosts[host.endpoint] = 'ssh-ed25519 ${config['fingerprint']}';
    final agent = McpAgent.create('fixture', [host.id], mode: McpMode.smart);
    repo.mcpAgents.add(agent.toJson());
    final approvals = <McpApproval>[];
    Completer<bool>? decision;
    Completer<void>? pendingApproval;
    final server = McpServer(
      repo,
      approve: (a) async {
        approvals.add(a);
        if (decision != null) {
          pendingApproval!.complete();
          return decision.future;
        }
        return true;
      },
      openSession: (h, title) async {
        final s = TerminalSession(title, host: h);
        await s.openSsh(repo, (_, _, _, _) async => false, (_) async => null);
        return s;
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
      final response = await request.close();
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      if (body['error'] != null) return body;
      return jsonDecode(
        (body['result']['content'] as List).single['text'] as String,
      ) as Map;
    }

    try {
      await server.start();
      final opened = await call('terminal_open', {'hostId': host.id});
      final id = opened['sessionId'];
      approvals.clear();
      final command = "printf 'command-out'; printf 'command-err' >&2; exit 7";
      final started = await call('exec_start', {
        'sessionId': id,
        'command': command,
      });
      expect(started['error'], isNull, reason: '$started');
      expect(utf8.decode(approvals.single.bytes!), contains(command));
      Map output = {};
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      do {
        output = await call('exec_read', {
          'sessionId': id,
          'commandId': started['commandId'],
        });
        if (output['running'] == false) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      } while (DateTime.now().isBefore(deadline));
      expect(
        utf8.decode(base64.decode(output['stdout'] as String)),
        'command-out',
      );
      expect(
        utf8.decode(base64.decode(output['stderr'] as String)),
        'command-err',
      );
      expect(output['exitCode'], 7);
      expect(approvals, hasLength(1));
      // Polling a running process must not advance past bytes not received.
      expect(output['nextStdoutOffset'], 11);
      expect(output['nextStderrOffset'], 11);
      final drained = await call('exec_read', {
        'sessionId': id,
        'commandId': started['commandId'],
        'stdoutOffset': output['nextStdoutOffset'],
        'stderrOffset': output['nextStderrOffset'],
      });
      expect(drained['stdout'], '');
      expect(drained['stderr'], '');
      final noisy = await call('exec_start', {
        'sessionId': id,
        'command': "head -c 300000 /dev/zero",
      });
      Map bounded = {};
      final noisyDeadline = DateTime.now().add(const Duration(seconds: 5));
      do {
        bounded = await call('exec_read', {
          'sessionId': id,
          'commandId': noisy['commandId'],
        });
        if (bounded['running'] == false) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      } while (DateTime.now().isBefore(noisyDeadline));
      expect(bounded['stdoutBytes'], 262144);
      expect(bounded['truncated'], true);
      expect(base64.decode(bounded['stdout'] as String), hasLength(32768));
      await call('exec_close', {
        'sessionId': id,
        'commandId': noisy['commandId'],
      });
      approvals.clear();
      final remote = '$fixture/mcp-created.bin';
      final data = [0, 1, 127, 255];
      final written = await call('sftp_write', {
        'sessionId': id,
        'path': remote,
        'base64': base64.encode(data),
      });
      expect(written['error'], isNull, reason: '$written');
      expect(await File(remote).readAsBytes(), data);
      final read = await call('sftp_read', {'sessionId': id, 'path': remote});
      expect(base64.decode(read['base64'] as String), data);
      expect(
        approvals,
        hasLength(1),
        reason: 'smart read does not request approval',
      );
      final duplicate = await call('sftp_write', {
        'sessionId': id,
        'path': remote,
        'base64': base64.encode([9]),
      });
      expect(duplicate['error'], isNotNull);
      expect(await File(remote).readAsBytes(), data);
      await call('sftp_rename', {
        'sessionId': id,
        'path': remote,
        'destination': '$remote.moved',
      });
      expect(await File('$remote.moved').exists(), true);
      await call('sftp_remove', {'sessionId': id, 'path': '$remote.moved'});
      expect(await File('$remote.moved').exists(), false);
      final denied = await call('sftp_read', {
        'sessionId': 'not-owned',
        'path': remote,
      });
      expect(denied['error'], isNotNull);
      final localPath = await call('sftp_write', {
        'sessionId': id,
        'path': remote,
        'base64': '',
        'localPath': '/home/user/.ssh/id_ed25519',
      });
      expect(localPath['error'], isNotNull);
      final batchA = File('$fixture/batch-a')..writeAsStringSync('a');
      final batchB = File('$fixture/batch-b')..writeAsStringSync('b');
      final conflict = File('$fixture/batch-conflict')
        ..writeAsStringSync('keep');
      approvals.clear();
      final movedBatch = await call('sftp_batch', {
        'sessionId': id,
        'operations': [
          {
            'operation': 'rename',
            'path': batchA.path,
            'destination': '${batchA.path}.moved',
          },
          {
            'operation': 'rename',
            'path': batchB.path,
            'destination': conflict.path,
          },
          {'operation': 'remove', 'path': conflict.path},
        ],
      });
      expect(movedBatch['completedCount'], 1);
      expect(movedBatch['failedIndex'], 1);
      expect(await File('${batchA.path}.moved').readAsString(), 'a');
      expect(await batchB.readAsString(), 'b');
      expect(await conflict.readAsString(), 'keep');
      expect(approvals, hasLength(1));
      expect(utf8.decode(approvals.single.bytes!), contains(conflict.path));
      final removedBatch = await call('sftp_batch', {
        'sessionId': id,
        'operations': [
          {'operation': 'remove', 'path': '${batchA.path}.moved'},
          {'operation': 'remove', 'path': batchB.path},
        ],
      });
      expect(removedBatch['completedCount'], 2);
      expect(await batchB.exists(), false);
      expect(await File('${batchA.path}.moved').exists(), false);
      final largeBytes = Uint8List.fromList(
        List.generate(150000, (i) => i % 251),
      );
      String digest(Uint8List bytes) => SHA256Digest()
          .process(bytes)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final tooLarge = await call('sftp_upload_begin', {
        'sessionId': id,
        'path': '$fixture/over-limit.bin',
        'size': 67108865,
        'sha256': digest(largeBytes),
      });
      expect(
        tooLarge['error'],
        isNotNull,
        reason: 'single upload must fit the documented audit budget',
      );
      final uploadPath = '$fixture/mcp-large.bin';
      final upload = await call('sftp_upload_begin', {
        'sessionId': id,
        'path': uploadPath,
        'size': largeBytes.length,
        'sha256': digest(largeBytes),
      });
      expect(upload['uploadId'], isA<String>(), reason: '$upload');
      final uploadId = upload['uploadId'];
      expect(await File(uploadPath).exists(), false);
      for (var offset = 0; offset < largeBytes.length; offset += 60000) {
        final chunk = largeBytes.sublist(
          offset,
          (offset + 60000).clamp(0, largeBytes.length),
        );
        final sent = await call('sftp_upload_chunk', {
          'sessionId': id,
          'uploadId': uploadId,
          'offset': offset,
          'base64': base64.encode(chunk),
        });
        expect(sent['nextOffset'], offset + chunk.length, reason: '$sent');
      }
      final finish = await call('sftp_upload_finish', {
        'sessionId': id,
        'uploadId': uploadId,
      });
      expect(finish['written'], 150000, reason: '$finish');
      expect(await File(uploadPath).readAsBytes(), largeBytes);
      final bad = await call('sftp_upload_begin', {
        'sessionId': id,
        'path': '$uploadPath.bad',
        'size': 3,
        'sha256': digest(Uint8List.fromList([1, 2, 3])),
      });
      await call('sftp_upload_chunk', {
        'sessionId': id,
        'uploadId': bad['uploadId'],
        'offset': 0,
        'base64': base64.encode([9, 9, 9]),
      });
      expect(
        (await call('sftp_upload_finish', {
          'sessionId': id,
          'uploadId': bad['uploadId'],
        }))['error'],
        isNotNull,
      );
      expect(await File('$uploadPath.bad').exists(), false);
      await call('sftp_upload_abort', {
        'sessionId': id,
        'uploadId': bad['uploadId'],
      });
      final interrupted = await call('sftp_upload_begin', {
        'sessionId': id,
        'path': '$uploadPath.locked',
        'size': 3,
        'sha256': digest(Uint8List.fromList([1, 2, 3])),
      });
      repo.locked = true;
      repo.epoch++;
      repo.locked = false;
      repo.epoch++;
      final expiredChunk = await call('sftp_upload_chunk', {
        'sessionId': id,
        'uploadId': interrupted['uploadId'],
        'offset': 0,
        'base64': base64.encode([1, 2, 3]),
      });
      expect(
        expiredChunk['error'],
        isNotNull,
        reason: 'upload begun before lock cannot resume after unlock',
      );
      await call('sftp_upload_abort', {
        'sessionId': id,
        'uploadId': interrupted['uploadId'],
      });
      final altered = await call('sftp_upload_begin', {
        'sessionId': id,
        'path': '$uploadPath.altered',
        'size': 3,
        'sha256': digest(Uint8List.fromList([1, 2, 3])),
      });
      await call('sftp_upload_chunk', {
        'sessionId': id,
        'uploadId': altered['uploadId'],
        'offset': 0,
        'base64': base64.encode([1, 2, 3]),
      });
      await File('$fixture/.salp-mcp-${altered['uploadId']}.part')
          .writeAsBytes([9, 9, 9]);
      final alteredFinish = await call('sftp_upload_finish', {
        'sessionId': id,
        'uploadId': altered['uploadId'],
      });
      expect(
        alteredFinish['error'],
        isNotNull,
        reason: 'verify remote bytes before publication',
      );
      expect(await File('$uploadPath.altered').exists(), false);
      await call('sftp_upload_abort', {
        'sessionId': id,
        'uploadId': altered['uploadId'],
      });
      decision = Completer<bool>();
      pendingApproval = Completer<void>();
      final stale = call('sftp_write', {
        'sessionId': id,
        'path': '$fixture/stale-approval.bin',
        'base64': base64.encode([1, 2, 3]),
      });
      await pendingApproval.future;
      repo.locked = true;
      repo.epoch++;
      repo.locked = false;
      repo.epoch++;
      decision.complete(true);
      expect((await stale)['error'], isNotNull);
      expect(await File('$fixture/stale-approval.bin').exists(), false);
      decision = null;
      repo.locked = true;
      repo.epoch++;
      final locked = await call('exec_read', {
        'sessionId': id,
        'commandId': started['commandId'],
      });
      expect(locked['error']['message'], '需要解锁 salp');
      await server.close();
      final auditFiles = await Directory('${repo.directory.path}/mcp-audit')
          .list()
          .where((f) => f is File)
          .cast<File>()
          .toList();
      final audit = <Map<String, dynamic>>[];
      for (final file in auditFiles) {
        audit.addAll(await SessionLog.read(file, repo.key));
      }
      final text = jsonEncode(audit);
      expect(text, contains('exec_start'));
      expect(text, contains('sftp_write'));
      expect(text, isNot(contains('command-out')));
      expect(text, isNot(contains('command-err')));
      expect(text, isNot(contains('mcp-created.bin')));
      expect(text, isNot(contains(agent.token)));
    } finally {
      http.close(force: true);
      await server.close();
    }
  }, skip: fixture == null ? 'Run tool/verify_ssh.py' : false);
}
