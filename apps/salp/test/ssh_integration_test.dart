import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/connection.dart';
import 'package:salp/core/tunnels.dart';
import 'package:salp/core/sftp_session.dart';
import 'package:salp/core/mcp.dart';

void main() {
  final fixture = Platform.environment['SALP_SSH_FIXTURE'];
  group(
    'local OpenSSH interoperability',
    skip: fixture == null ? 'Run tool/verify_ssh.py' : false,
    () {
      late Repository repo;
      late Host host;
      setUp(() async {
        final config = jsonDecode(
          await File('$fixture/public.json').readAsString(),
        ) as Map<String, dynamic>;
        repo = Repository(Directory('$fixture/repository'), Uint8List(32));
        await repo.directory.create(recursive: true);
        host = Host(
          id: 'target',
          name: 'test',
          address: '127.0.0.1',
          port: config['port'] as int,
          username: config['username'] as String,
        );
        repo.hosts.add(host);
        repo.credentials[host.id] = Credential(
          privateKey: await File('$fixture/client_key').readAsString(),
        );
        repo.knownHosts[host.endpoint] = 'ssh-ed25519 ${config['fingerprint']}';
      });
      test('authenticated MCP owns a real SSH terminal and cannot read while locked', () async {
        final agent = McpAgent.create('fixture-agent', [
          host.id,
        ], mode: McpMode.yolo);
        repo.mcpAgents.add(agent.toJson());
        final server = McpServer(
          repo,
          approve: (_) async => false,
          openSession: (h, title) async {
            final terminal = TerminalSession(title, host: h);
            await terminal.openSsh(
              repo,
              (_, _, _, _) async => false,
              (_) async => null,
            );
            return terminal;
          },
        );
        await server.start();
        final http = HttpClient();
        Future<Map<String, dynamic>> call(
          String name,
          Map<String, dynamic> args,
        ) async {
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
          final body = jsonDecode(
            await utf8.decoder.bind(response).join(),
          ) as Map<String, dynamic>;
          if (body['error'] != null) return body;
          return jsonDecode(
            ((body['result'] as Map)['content'] as List).first['text']
                as String,
          ) as Map<String, dynamic>;
        }

        try {
          final opened = await call('terminal_open', {'hostId': host.id});
          expect(opened['status'], '已连接');
          final id = opened['sessionId'] as String;
          final sent = await call('terminal_write', {
            'sessionId': id,
            'base64': base64.encode(
              utf8.encode("printf '%s%s\\n' 'SALP_MCP_' 'EXECUTED'\n"),
            ),
          });
          expect(sent['status'], contains('已提交'));
          var output = '';
          final limit = DateTime.now().add(const Duration(seconds: 5));
          while (!output.contains('SALP_MCP_EXECUTED') &&
              DateTime.now().isBefore(limit)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            output =
                (await call('terminal_read', {'sessionId': id}))['text']
                    as String;
          }
          expect(output, contains('SALP_MCP_EXECUTED'));
          repo.locked = true;
          repo.epoch++;
          final blocked = await call('terminal_read', {'sessionId': id});
          expect(jsonEncode(blocked), contains('需要解锁 salp'));
          expect(jsonEncode(blocked), isNot(contains('SALP_MCP_EXECUTED')));
          repo.locked = false;
          repo.epoch++;
          expect(
            (await call('terminal_close', {'sessionId': id}))['closed'],
            true,
          );
        } finally {
          http.close(force: true);
          await server.close();
        }
      });
      test('exec authorization is checked after opening a channel and before command dispatch', () async {
        final ssh = await SshConnection.connect(
          repo,
          host,
          (_, _, _, _) async => false,
          (_) async => null,
        );
        final marker = File('$fixture/forbidden-exec');
        try {
          var checks = 0;
          await expectLater(
            ssh.client.execute(
              "touch '${marker.path}'",
              authorize: () {
                if (++checks >= 2) {
                  throw StateError('revoked during channel open');
                }
              },
            ),
            throwsStateError,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(await marker.exists(), false);
          expect(checks, greaterThanOrEqualTo(2));
        } finally {
          await ssh.close();
        }
      });
      test(
        'timed-out SSH channel setup is cleaned up when replies arrive late',
        () async {
          final config = jsonDecode(
            await File('$fixture/public.json').readAsString(),
          ) as Map;
          final socket = _PausedInputSocket(
            await SSHSocket.connect(host.address, host.port),
          );
          final client = SSHClient(
            socket,
            username: host.username,
            identities: SSHKeyPair.fromPem(
              await File('$fixture/client_key').readAsString(),
            ),
            onVerifyHostKey: (_, bytes) async =>
                utf8.decode(bytes) == config['fingerprint'],
          );
          try {
            await client.authenticated;
            for (final sftp in [false, true]) {
              socket.pause();
              final marker = File('$fixture/timeout-${sftp ? 'sftp' : 'exec'}');
              final operation = sftp
                  ? client.sftp(timeout: const Duration(milliseconds: 80))
                  : client.execute(
                      "touch '${marker.path}'",
                      timeout: const Duration(milliseconds: 80),
                    );
              await expectLater(
                operation.timeout(const Duration(seconds: 2)),
                throwsA(
                  isA<TimeoutException>().having(
                    (e) => e.message,
                    'bounded channel setup',
                    contains('SSH channel open'),
                  ),
                ),
              );
              socket.resume();
              expect(
                utf8.decode(await client.run('printf still-connected')),
                'still-connected',
              );
              expect(await marker.exists(), false);
            }
          } finally {
            socket.resume();
            client.close();
          }
        },
        timeout: const Timeout(Duration(seconds: 50)),
      );
      test('desktop ssh-agent authenticates without reading a private key into salp', () async {
        repo.credentials[host.id] = const Credential(useAgent: true);
        final ssh = await SshConnection.connect(
          repo,
          host,
          (_, _, _, _) async => false,
          (_) async => null,
        );
        try {
          expect(
            utf8.decode(await ssh.client.run("printf agent-authenticated")),
            'agent-authenticated',
          );
        } finally {
          await ssh.close();
        }
      });
      test('Mosh input still queued at lock is never executed after unlock', () async {
        final session = TerminalSession('mosh lock fixture', host: host);
        try {
          await session.openMosh(
            repo,
            (_, _, _, _) async => false,
            (_) async => null,
          );
          expect(session.connected, true, reason: session.error);
          // openMosh just sent its initial size packet, so its next keystroke
          // waits for the transport pacing timer. Lock before that timer runs.
          final sending = session.send(
            "printf '%s%s\\n' 'SALP_FORBIDDEN_' 'QUEUED'\n",
          );
          session.setLocked(true);
          await sending;
          await Future<void>.delayed(const Duration(milliseconds: 500));
          session.setLocked(false);
          await session.send("printf '%s%s\\n' 'SALP_FRESH_' 'EXECUTED'\n");
          final limit = DateTime.now().add(const Duration(seconds: 12));
          while (!session.terminal.buffer.getText().contains(
                'SALP_FRESH_EXECUTED',
              ) &&
              DateTime.now().isBefore(limit)) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          final output = session.terminal.buffer.getText();
          expect(output, contains('SALP_FRESH_EXECUTED'));
          expect(output, isNot(contains('SALP_FORBIDDEN_QUEUED')));
          await session.send('exit\n');
        } finally {
          await session.close();
        }
      });
      test('real Mosh server renders interactive input over UDP', () async {
        final session = TerminalSession('mosh fixture', host: host);
        try {
          await session.openMosh(
            repo,
            (_, _, _, _) async => false,
            (_) async => null,
          );
          expect(session.connected, true, reason: session.error);
          await session.send("printf '%s%s\\n' 'SALP_MOSH_' 'EXECUTED'\n");
          final limit = DateTime.now().add(const Duration(seconds: 12));
          while (!session.terminal.buffer.getText().contains(
                'SALP_MOSH_EXECUTED',
              ) &&
              DateTime.now().isBefore(limit)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(
            session.terminal.buffer.getText(),
            contains('SALP_MOSH_EXECUTED'),
          );
          await session.send('exit\n');
        } finally {
          await session.close();
        }
      });
      test(
        'SOCKS5 dynamic tunnel forwards a binary payload and closes',
        () async {
          final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          final peers = <Socket>[];
          final echoSub = echo.listen((socket) {
            peers.add(socket);
            socket.listen(socket.add);
          });
          final ssh = await SshConnection.connect(
            repo,
            host,
            (_, _, _, _) async => false,
            (_) async => null,
          );
          Tunnel? tunnel;
          Socket? socket;
          try {
            tunnel = await Tunnel.dynamic(ssh.client, 0);
            final port = int.parse(tunnel.description.split(':').last);
            socket = await Socket.connect('127.0.0.1', port);
            final iterator = StreamIterator<int>(socket.expand((b) => b));
            Future<List<int>> read(int length) async {
              final result = <int>[];
              for (var i = 0; i < length; i++) {
                if (!await iterator.moveNext().timeout(
                  const Duration(seconds: 5),
                )) {
                  throw StateError('Unexpected EOF');
                }
                result.add(iterator.current);
              }
              return result;
            }

            socket.add([5, 1, 0]);
            expect(await read(2), [5, 0]);
            socket.add([
              5,
              1,
              0,
              1,
              127,
              0,
              0,
              1,
              echo.port >> 8,
              echo.port & 255,
            ]);
            final reply = await read(10);
            expect(reply.take(2), [5, 0]);
            socket.add([0, 1, 128, 255]);
            expect(await read(4), [0, 1, 128, 255]);
            socket.destroy();
            await iterator.cancel();
            await tunnel.close().timeout(const Duration(seconds: 5));
            expect(tunnel.active, false);
          } finally {
            socket?.destroy();
            if (tunnel?.active == true) await tunnel!.close();
            await ssh.close();
            for (final p in peers) {
              p.destroy();
            }
            await echoSub.cancel();
            await echo.close();
          }
        },
      );
      test(
        'trusted SSH executes commands and preserves interactive UTF-8 input',
        () async {
          final ssh = await SshConnection.connect(
            repo,
            host,
            (_, _, _, _) async => false,
            (_) async => null,
          );
          try {
            final output = await ssh.client.run("printf 'salp-%s' 'verified'");
            expect(utf8.decode(output), 'salp-verified');
            final shell = await ssh.client.execute('cat');
            final response = shell.stdout.expand((x) => x).toList();
            shell.write(Uint8List.fromList(utf8.encode('中文\x00\n')));
            await shell.stdin.close();
            expect(await response, utf8.encode('中文\x00\n'));
          } finally {
            await ssh.close();
          }
        },
      );
      test('host-key changes block authentication and do not silently replace trust', () async {
        repo.knownHosts[host.endpoint] = 'ssh-ed25519 SHA256:wrong';
        var prompted = false;
        await expectLater(
          SshConnection.connect(repo, host, (h, a, f, p) async {
            prompted = true;
            expect(p, 'ssh-ed25519 SHA256:wrong');
            return false;
          }, (_) async => null),
          throwsA(anything),
        );
        expect(prompted, true);
        expect(repo.knownHosts[host.endpoint], 'ssh-ed25519 SHA256:wrong');
      });
      test('two jump hosts and final target each authenticate', () async {
        final first = Host(
          id: 'jump1',
          name: 'jump1',
          address: host.address,
          port: host.port,
          username: host.username,
        );
        final second = Host(
          id: 'jump2',
          name: 'jump2',
          address: host.address,
          port: host.port,
          username: host.username,
        );
        repo.hosts.addAll([first, second]);
        repo.credentials[first.id] = repo.credentials[host.id]!;
        repo.credentials[second.id] = repo.credentials[host.id]!;
        final target = Host(
          id: host.id,
          name: host.name,
          address: host.address,
          port: host.port,
          username: host.username,
          jumpIds: [first.id, second.id],
        );
        final ssh = await SshConnection.connect(
          repo,
          target,
          (_, _, _, _) async => false,
          (_) async => null,
        );
        try {
          expect(ssh.clients.length, 3);
          expect(
            utf8.decode(await ssh.client.run("printf 'three-endpoints'")),
            'three-endpoints',
          );
        } finally {
          await ssh.close();
        }
      });
      test('SFTP streams files with invalid UTF-8 names and never replaces conflicts', () async {
        final ssh = await SshConnection.connect(
          repo,
          host,
          (_, _, _, _) async => false,
          (_) async => null,
        );
        try {
          final sftp = await ssh.client.sftp();
          final path = Uint8List.fromList([
            ...utf8.encode('$fixture/'),
            0x80,
            0xff,
          ]);
          final file = await sftp.open(
            path,
            mode:
                SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.exclusive,
          );
          await file.writeBytes(Uint8List.fromList([0, 1, 2, 0xff]));
          await file.close();
          final names = await sftp.listdir(fixture!);
          final raw = names.singleWhere(
            (n) => n.filenameBytes.length == 2 && n.filenameBytes.first == 0x80,
          );
          expect(raw.filenameBytes, [0x80, 0xff]);
          final read = await sftp.open(
            Uint8List.fromList([
              ...utf8.encode('$fixture/'),
              ...raw.filenameBytes,
            ]),
          );
          expect(await read.readBytes(), [0, 1, 2, 0xff]);
          await read.close();
          final target = '$fixture/existing.txt';
          final existing = await sftp.open(
            target,
            mode:
                SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.exclusive,
          );
          await existing.writeBytes(Uint8List.fromList([9]));
          await existing.close();
          await expectLater(
            sftp.renameNoReplace(path, target),
            throwsA(isA<SftpStatusError>()),
          );
          final preserved = await sftp.open(target);
          expect(await preserved.readBytes(), [9]);
          await preserved.close();
          await sftp.remove(path);
          await sftp.remove(target);
          await sftp.close();
        } finally {
          await ssh.close();
        }
      });
      test(
        'SFTP preview started before lock stays invalid after unlock',
        () async {
          final file = File('$fixture/preview-lock.txt');
          await file.writeAsString('private preview');
          final files = SftpSession(host);
          try {
            await files.open(
              repo,
              (_, _, _, _) async => false,
              (_) async => null,
            );
            await files.list(Uint8List.fromList(utf8.encode(fixture!)));
            final entry = files.entries.singleWhere(
              (e) => e.filename == 'preview-lock.txt',
            );
            final pending = files.preview(entry);
            files.setLocked(true);
            files.setLocked(false);
            await expectLater(pending, throwsStateError);
            expect(utf8.decode(await files.preview(entry)), 'private preview');
          } finally {
            await files.close();
            await file.delete();
          }
        },
      );
      test('SFTP queue downloads 100 files with exact bytes and bounded completion', () async {
        final session = SftpSession(host);
        final remoteDir = await Directory('$fixture/batch-remote').create();
        final localDir = await Directory('$fixture/batch-local').create();
        try {
          for (var i = 0; i < 100; i++) {
            await File(
              '${remoteDir.path}/file-$i.bin',
            ).writeAsBytes(List.generate(1024 + i, (j) => (j * 17 + i) % 256));
          }
          await session.open(
            repo,
            (_, _, _, _) async => false,
            (_) async => null,
          );
          await session.list(Uint8List.fromList(utf8.encode(remoteDir.path)));
          expect(session.entries.length, 100);
          for (final entry in session.entries) {
            session.download(
              entry,
              localDir.path,
              (_) async => ConflictChoice.skip,
            );
          }
          await waitTransfer(session, session.jobs.last);
          expect(
            session.jobs.where((j) => j.state == TransferState.complete).length,
            100,
          );
          for (var i = 0; i < 100; i++) {
            expect(
              await File('${localDir.path}/file-$i.bin').readAsBytes(),
              List.generate(1024 + i, (j) => (j * 17 + i) % 256),
            );
          }
          expect((await localDir.list().toList()).length, 100);
        } finally {
          await session.close();
        }
      });
      test(
        'SFTP queued download, keep-both and cancellation preserve files',
        () async {
          final session = SftpSession(host);
          await session.open(
            repo,
            (_, _, _, _) async => false,
            (_) async => null,
          );
          expect(session.status, '已连接');
          final remoteDir = await Directory('$fixture/transfer').create();
          final destination = await Directory('$fixture/downloads').create();
          final bytes = List<int>.generate(150000, (i) => i % 251);
          await File('${remoteDir.path}/original.bin').writeAsBytes(bytes);
          await File('${remoteDir.path}/cancel.bin').writeAsBytes(bytes);
          await File('${destination.path}/original.bin')
              .writeAsString('keep-original');
          try {
            await session.list(Uint8List.fromList(utf8.encode(remoteDir.path)));
            final entry = session.entries.singleWhere(
              (e) => e.filename == 'original.bin',
            );
            session.download(
              entry,
              destination.path,
              (_) async => ConflictChoice.keepBoth,
            );
            final job = session.jobs.last;
            await waitTransfer(session, job);
            expect(job.state, TransferState.complete, reason: job.error);
            expect(
              await File('${destination.path}/original.bin').readAsString(),
              'keep-original',
            );
            final copy = (await destination.list().toList()).singleWhere(
              (f) => f.path.contains('.copy-'),
            ) as File;
            expect(await copy.readAsBytes(), bytes);
            final gate = Completer<void>();
            final running = TransferJob('hold', false, (_) => gate.future);
            session.enqueue(running);
            session.download(
              session.entries.singleWhere((e) => e.filename == 'cancel.bin'),
              destination.path,
              (_) async => ConflictChoice.skip,
            );
            final cancelled = session.jobs.last;
            session.cancel(cancelled);
            gate.complete();
            await waitTransfer(session, running);
            expect(cancelled.state, TransferState.cancelled);
            expect(
              await File('${destination.path}/cancel.bin').exists(),
              false,
            );
            session.retry(cancelled);
            await waitTransfer(session, cancelled);
            expect(
              cancelled.state,
              TransferState.complete,
              reason: cancelled.error,
            );
            expect(
              await File('${destination.path}/cancel.bin').readAsBytes(),
              bytes,
            );
          } finally {
            await session.close();
          }
        },
      );
      test('local and remote tunnel payloads round-trip and close', () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final accepted = <Socket>[];
        final listener = server.listen((socket) {
          accepted.add(socket);
          socket.listen(socket.add);
        });
        final ssh = await SshConnection.connect(
          repo,
          host,
          (_, _, _, _) async => false,
          (_) async => null,
        );
        try {
          for (final remote in [false, true]) {
            final reservation = await ServerSocket.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final port = reservation.port;
            await reservation.close();
            final tunnel = remote
                ? await Tunnel.remote(
                    ssh.client,
                    port,
                    '127.0.0.1',
                    server.port,
                  )
                : await Tunnel.local(
                    ssh.client,
                    port,
                    '127.0.0.1',
                    server.port,
                  );
            final socket = await Socket.connect('127.0.0.1', port);
            final received = <int>[];
            final receivedDone = Completer<void>();
            late final StreamSubscription<List<int>> subscription;
            subscription = socket.listen((chunk) {
              received.addAll(chunk);
              if (received.length >= 4 && !receivedDone.isCompleted) {
                receivedDone.complete();
                unawaited(subscription.cancel());
              }
            });
            socket.add([0, 1, 128, 255]);
            await socket.flush();
            await receivedDone.future.timeout(const Duration(seconds: 5));
            expect(received.sublist(0, 4), [0, 1, 128, 255]);
            await subscription.cancel();
            socket.destroy();
            await tunnel.close().timeout(const Duration(seconds: 5));
            expect(tunnel.active, false);
          }
        } finally {
          await ssh.close();
          await listener.cancel();
          await server.close();
          for (final socket in accepted) {
            socket.destroy();
          }
        }
      });
    },
  );
}

Future<void> waitTransfer(SftpSession session, TransferJob job) async {
  final done = Completer<void>();
  void changed() {
    if (job.state != TransferState.queued &&
        job.state != TransferState.running &&
        !done.isCompleted) {
      done.complete();
    }
  }

  session.addListener(changed);
  changed();
  try {
    await done.future.timeout(const Duration(seconds: 15));
  } finally {
    session.removeListener(changed);
  }
}

// Gate replies after real OpenSSH authentication to exercise late channel opens.
class _PausedInputSocket implements SSHSocket {
  _PausedInputSocket(this.inner) {
    _incoming = inner.stream.listen(
      _output.add,
      onError: _output.addError,
      onDone: _output.close,
    );
  }
  final SSHSocket inner;
  final _output = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _incoming;
  void pause() => _incoming.pause();
  void resume() => _incoming.resume();
  @override
  Stream<Uint8List> get stream => _output.stream;
  @override
  StreamSink<List<int>> get sink => inner.sink;
  @override
  Future<void> get done => inner.done;
  @override
  Future<void> close() => inner.close();
  @override
  void destroy() => inner.destroy();
  @override
  Future<void> flush() => inner.flush();
}
