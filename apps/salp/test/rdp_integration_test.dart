import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/rdp.dart';

void main() {
  test(
    'rejecting the actual RDP certificate never establishes a desktop',
    () async {
      final folder = await Directory.systemTemp.createTemp('salp-rdp-reject-');
      final repo = Repository(folder, Uint8List(32));
      var prompts = 0;
      final session = RdpSession(
        Host(
          id: 'reject',
          name: 'reject',
          address: '127.0.0.1',
          port: int.parse(Platform.environment['SALP_RDP_PORT']!),
          protocol: Protocol.rdp,
        ),
        verifyCertificate: (_) async {
          prompts++;
          return false;
        },
      );
      try {
        await session.open(
          repo,
          (_, _, _, _) async => false,
          (_) async => null,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (session.error == null && DateTime.now().isBefore(deadline)) {
          expect(session.frame, isNull);
          expect(session.connected, false);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(prompts, 1);
        expect(session.error, isNotNull);
        expect(session.connected, false);
        expect(session.frame, isNull);
      } finally {
        await session.close();
        await folder.delete(recursive: true);
      }
    },
    skip: Platform.environment['SALP_RDP_PORT'] == null
        ? 'Run tool/verify_rdp.py'
        : false,
  );
  test(
    'Dart RDP session receives native framebuffer and preserves lock and close lifecycle',
    () async {
      final folder = await Directory.systemTemp.createTemp('salp-dart-rdp-');
      final repo = Repository(folder, Uint8List(32));
      final sshFixture = Platform.environment['SALP_SSH_FIXTURE'];
      if (sshFixture != null) {
        final config = jsonDecode(
          await File('$sshFixture/public.json').readAsString(),
        ) as Map<String, dynamic>;
        final gateway = Host(
          id: 'jump',
          name: 'jump',
          address: '127.0.0.1',
          port: config['port'] as int,
          username: config['username'] as String,
        );
        repo.hosts.add(gateway);
        repo.credentials['jump'] = Credential(
          privateKey: await File('$sshFixture/client_key').readAsString(),
        );
        repo.knownHosts[gateway.endpoint] =
            'ssh-ed25519 ${config['fingerprint']}';
      }
      var certificates = 0;
      final session = RdpSession(
        Host(
          id: 'rdp',
          name: 'fixture',
          address: '127.0.0.1',
          port: int.parse(Platform.environment['SALP_RDP_PORT']!),
          username: 'fixture',
          protocol: Protocol.rdp,
          jumpIds: sshFixture == null ? [] : ['jump'],
        ),
        verifyCertificate: (details) async {
          certificates++;
          expect(details, isNotEmpty);
          return true;
        },
      );
      try {
        await session.open(
          repo,
          (_, _, _, _) async => false,
          (_) async => null,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (session.frame == null &&
            session.error == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(session.connected, true, reason: session.error);
        expect(session.frame?.length, 1280 * 720 * 4);
        expect(certificates, 1);
        // A shortcut must be sent as physical scan codes, while committed
        // Unicode text (including a supplementary-plane character) uses UTF-16.
        session.key(0xffe3, true);
        session.key(0x63, true);
        session.key(0x63, false);
        session.key(0xffe3, false);
        session.key(0x0101f600, true);
        session.key(0x0101f600, false);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        session.setLocked(true);
        final frame = session.frame;
        session.key(97, true);
        session.pointer(10, 10, 1);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(identical(frame, session.frame), true);
        session.setLocked(false);
        session.key(97, false);
        session.pointer(10, 10, 0);
      } finally {
        await session.close();
        await folder.delete(recursive: true);
      }
      expect(session.connected, false);
      expect(session.frame, isNull);
    },
    skip: Platform.environment['SALP_RDP_PORT'] == null
        ? 'Run tool/verify_rdp.py'
        : false,
  );
}
