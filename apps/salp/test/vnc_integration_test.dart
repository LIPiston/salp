import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/vnc.dart';

void main() {
  final fixture = Platform.environment['SALP_VNC_FIXTURE'];
  test(
    'TigerVNC authentication, exact pixels and OS input work directly and through OpenSSH',
    () async {
      final config = jsonDecode(
        await File('$fixture/public.json').readAsString(),
      ) as Map<String, dynamic>;
      final directory = await Directory('$fixture/repo').create();
      final repo = Repository(directory, Uint8List(32));
      final gateway = Host(
        id: 'jump',
        name: 'jump',
        address: '127.0.0.1',
        port: config['ssh_port'] as int,
        username: config['username'] as String,
      );
      repo.hosts.add(gateway);
      repo.credentials[gateway.id] = Credential(
        privateKey: await File('$fixture/client_key').readAsString(),
      );
      repo.knownHosts[gateway.endpoint] =
          'ssh-ed25519 ${config['fingerprint']}';
      Host host(List<String> jumps) => Host(
        id: 'vnc',
        name: 'vnc',
        address: '127.0.0.1',
        port: config['vnc_port'] as int,
        protocol: Protocol.vnc,
        jumpIds: jumps,
      );
      Future<void> until(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(ready(), true);
      }

      List<Map<String, dynamic>> events() {
        final file = File('$fixture/events.jsonl');
        return file.existsSync()
            ? file
                  .readAsLinesSync()
                  .map((s) => jsonDecode(s) as Map<String, dynamic>)
                  .toList()
            : [];
      }

      repo.credentials['vnc'] = const Credential(password: 'invalid');
      final rejected = VncSession(host([]));
      try {
        await rejected.open(
          repo,
          (_, _, _, _) async => false,
          (_) async => null,
        );
        expect(rejected.connected, false);
        expect(rejected.frame, isNull);
        expect(rejected.error, isNotNull);
      } finally {
        await rejected.close();
      }
      repo.credentials['vnc'] = const Credential(password: 'fixture8');
      for (final jumps in [
        <String>[],
        ['jump'],
      ]) {
        final session = VncSession(host(jumps));
        try {
          await session.open(
            repo,
            (_, _, _, _) async => false,
            (_) async => null,
          );
          expect(session.connected, true, reason: session.error);
          await until(() => session.frame != null || session.error != null);
          expect(session.error, isNull);
          expect([session.width, session.height], [640, 480]);
          final pixels = session.frame!;
          expect(pixels.sublist((10 * 640 + 10) * 4, (10 * 640 + 10) * 4 + 4), [
            255,
            0,
            0,
            255,
          ]);
          expect(
            pixels.sublist((10 * 640 + 500) * 4, (10 * 640 + 500) * 4 + 4),
            [0, 0, 255, 255],
          );
          final key = jumps.isEmpty ? 0x61 : 0x64;
          session.pointer(40, 40, 1);
          session.pointer(40, 40, 0);
          session.key(key, true);
          session.key(key, false);
          await until(() => events().any((e) => e['key'] == key));
          session.setLocked(true);
          session.key(0x62, true);
          session.key(0x62, false);
          session.pointer(200, 180, 1);
          session.pointer(200, 180, 0);
          session.setLocked(false);
          final marker = jumps.isEmpty ? 0x63 : 0x65;
          session.key(marker, true);
          session.key(marker, false);
          await until(() => events().any((e) => e['key'] == marker));
          expect(events().where((e) => e['key'] == 0x62), isEmpty);
          expect(
            events().where((e) => e['button'] == 1 && e['x'] == 200),
            isEmpty,
          );
          expect(
            events().where((e) => e['button'] == 1 && e['x'] == 40),
            isNotEmpty,
          );
        } finally {
          await session.close();
        }
        expect(session.frame, isNull);
        expect(session.connected, false);
      }
    },
    skip: fixture == null ? 'Run tool/verify_vnc.py' : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
