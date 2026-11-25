import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/ui/import_dialog.dart';

final class _ChosenFile extends PlatformFile {
  _ChosenFile(this.file);
  final File file;
  @override
  Uri get uri => file.uri;
  @override
  String get name => file.uri.pathSegments.last;
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
  @override
  Never get xFile => throw UnimplementedError();
}

class _SelectedImport extends FilePickerPlatform {
  _SelectedImport(this.directory);
  final Directory directory;
  @override
  Future<Uri?> pickDirectory({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => directory.uri;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _ChosenFile(File('${directory.path}/config'));
}

void main() {
  testWidgets(
    'selected Include directory is previewed before import commits the expanded host',
    (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('salp-import-dialog-'),
      );
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _SelectedImport(dir!);
      final repo = (await tester.runAsync(() async => Repository(dir, Uint8List(32))))!;
      try {
        await tester.runAsync(() async {
          await File('${dir.path}/config')
              .writeAsString('Include extra.conf\n');
          await File('${dir.path}/extra.conf').writeAsString(
            'Host imported\n HostName selected.test\n User deploy\n',
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ImportDialog(repository: repo)),
          ),
        );
        await tester.tap(find.text('选择 Include 允许目录（可选）'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('选择配置文件'));
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
            if (find.text('1 台主机可以导入').evaluate().isNotEmpty) break;
          }
        });
        await tester.pumpAndSettle();
        expect(find.text('1 台主机可以导入'), findsOneWidget);
        expect(repo.hosts, isEmpty);
        await tester.runAsync(() async {
          await tester.tap(find.text('导入预览中的主机'));
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (repo.hosts.isEmpty && DateTime.now().isBefore(deadline)) {
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        expect(repo.hosts.single.address, 'selected.test');
        expect(repo.hosts.single.username, 'deploy');
        expect(tester.takeException(), isNull);
      } finally {
        FilePickerPlatform.instance = previous;
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
}
