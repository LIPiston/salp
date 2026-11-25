import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:salp/core/ssh_agent.dart';

Uint8List _word(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> _string(List<int> bytes) => [..._word(bytes.length), ...bytes];

void main() {
  final fixture = Platform.environment['SALP_WINDOWS_AGENT_FIXTURE'];
  final prefix = Platform.environment['SALP_WINDOWS_AGENT_PIPE_PREFIX'];
  group(
    'Windows OpenSSH agent',
    skip: !Platform.isWindows || fixture == null
        ? 'Run tool/verify_windows_agent.py on Windows'
        : false,
    () {
      test('system agent signs verifiable data and rejects signing after lock', () async {
        var unlocked = true;
        final identities = await DesktopSshAgent('', () {
          if (!unlocked) throw StateError('locked');
        }).identities();
        final public = (await File(
          '$fixture/key.pub',
        ).readAsString()).split(' ')[1];
        final identity = identities.singleWhere(
          (value) => base64.encode(value.toPublicKey().encode()) == public,
        );
        final message = utf8.encode('salp Windows agent proof 中文\n');
        final signed = Uint8List.fromList([
          ...ascii.encode('SSHSIG'),
          ..._string(ascii.encode('salp-agent')),
          ..._string([]),
          ..._string(ascii.encode('sha512')),
          ..._string(SHA512Digest().process(Uint8List.fromList(message))),
        ]);
        final signature = await identity.sign(signed);
        final envelope = base64.encode([
          ...ascii.encode('SSHSIG'),
          ..._word(1),
          ..._string(identity.toPublicKey().encode()),
          ..._string(ascii.encode('salp-agent')),
          ..._string([]),
          ..._string(ascii.encode('sha512')),
          ..._string(signature.encode()),
        ]);
        final lines = <String>[];
        for (var i = 0; i < envelope.length; i += 70) {
          lines.add(envelope.substring(i, (i + 70).clamp(0, envelope.length)));
        }
        await File('$fixture/proof.sig').writeAsString(
          '-----BEGIN SSH SIGNATURE-----\n${lines.join('\n')}\n-----END SSH SIGNATURE-----\n',
        );
        final verify = await Process.start('ssh-keygen', [
          '-Y',
          'verify',
          '-f',
          '$fixture/allowed_signers',
          '-I',
          'fixture',
          '-n',
          'salp-agent',
          '-s',
          '$fixture/proof.sig',
        ]);
        final output = verify.stdout.transform(utf8.decoder).join();
        final errors = verify.stderr.transform(utf8.decoder).join();
        verify.stdin.add(message);
        await verify.stdin.close();
        expect(await verify.exitCode, 0, reason: await errors);
        expect(await output, contains('Good "salp-agent" signature'));
        unlocked = false;
        await expectLater(identity.sign(signed), throwsStateError);
        expect(await File('$fixture/key').exists(), true);
      });

      test('local named pipe handles fragmented responses', () async {
        final identities = await DesktopSshAgent(
          '$prefix-fragment',
          () {},
        ).identities();
        final public = (await File(
          '$fixture/key.pub',
        ).readAsString()).split(' ')[1];
        expect(identities, hasLength(1));
        expect(base64.encode(identities.single.toPublicKey().encode()), public);
      });

      test('pipe rejects oversized and truncated responses', () async {
        for (final mode in ['oversize', 'truncated']) {
          await expectLater(
            DesktopSshAgent('$prefix-$mode', () {}).identities(),
            throwsA(isA<StateError>()),
          );
        }
      });

      test(
        'unresponsive pipe times out while event loop stays responsive',
        () async {
          var ticks = 0;
          final timer = Timer.periodic(
            const Duration(milliseconds: 20),
            (_) => ticks++,
          );
          try {
            await expectLater(
              DesktopSshAgent(
                '$prefix-stall',
                () {},
              ).identities().timeout(const Duration(seconds: 22)),
              throwsA(
                isA<TimeoutException>().having(
                  (error) => error.message,
                  'agent deadline',
                  contains('ssh-agent'),
                ),
              ),
            );
            expect(ticks, greaterThan(100));
          } finally {
            timer.cancel();
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );

      test('lock cancels a pending pipe response promptly', () async {
        var unlocked = true;
        final pending = DesktopSshAgent('$prefix-revoked', () {
          if (!unlocked) throw StateError('locked');
        }).identities();
        final checked = expectLater(
          pending.timeout(const Duration(seconds: 3)),
          throwsStateError,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        unlocked = false;
        await checked;
      });

      test('remote pipes and ordinary files are refused', () async {
        for (final path in [
          r'\\remote\pipe\agent',
          '$fixture/key',
          r'\\.\C:\key',
        ]) {
          await expectLater(
            DesktopSshAgent(path, () {}).identities(),
            throwsFormatException,
          );
        }
      });
    },
  );
}
