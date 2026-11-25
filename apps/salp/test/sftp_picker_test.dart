import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/sftp_session.dart';
import 'package:salp/ui/sftp_view.dart';

class DeferredDirectoryPicker extends FilePickerPlatform {
  final result = Completer<Uri?>();
  final opened = Completer<void>();
  @override
  Future<Uri?> pickDirectory({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    opened.complete();
    return result.future;
  }
}

void main() {
  final fixture = Platform.environment['SALP_SSH_FIXTURE'];
  group(
    'SFTP picker authorization',
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
      testWidgets(
        'SFTP directory picker result from before lock cannot enqueue after unlock',
        (tester) async {
          final remoteDirectory = Directory('$fixture/picker-remote');
          final remote = File('${remoteDirectory.path}/picker-source.txt');
          final local = Directory('$fixture/picker-destination');
          final files = SftpSession(host);
          final previousPicker = FilePickerPlatform.instance;
          final picker = DeferredDirectoryPicker();
          FilePickerPlatform.instance = picker;
          try {
            await tester.runAsync(() async {
              await remoteDirectory.create();
              await remote.writeAsString('private fixture');
              await local.create();
              await files.open(
                repo,
                (_, _, _, _) async => false,
                (_) async => null,
              );
              await files.list(
                Uint8List.fromList(utf8.encode(remoteDirectory.path)),
              );
            });
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(body: SftpView(session: files)),
              ),
            );
            final row = find.widgetWithText(ListTile, 'picker-source.txt');
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            await tester.tap(
              find.descendant(of: row, matching: find.byType(Checkbox)),
            );
            await tester.pump();
            await tester.tap(find.byTooltip('下载所选'));
            expect(picker.opened.isCompleted, true);
            files.setLocked(true);
            files.setLocked(false);
            await tester.runAsync(() async {
              picker.result.complete(local.uri);
              await Future<void>.delayed(const Duration(milliseconds: 100));
            });
            await tester.pump();
            expect(
              files.jobs,
              isEmpty,
              reason: 'old picker result must not start a fresh transfer',
            );
            expect(await tester.runAsync(() => local.list().toList()), isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            FilePickerPlatform.instance = previousPicker;
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() async {
              await files.close();
              await remoteDirectory.delete(recursive: true);
              await local.delete(recursive: true);
            });
          }
        },
      );
    },
  );
}
