import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:salp/core/master_password.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/ui/workbench.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'system file picker preserves authorized editor; device screen lock still gates it',
    (tester) async {
      final directory = Directory(
        '${(await getApplicationSupportDirectory()).path}/picker-lock-fixture',
      );
      await directory.create(recursive: true);
      final repo = Repository(directory, Uint8List(32));
      repo.masterPassword = await MasterPassword.create(
        'fixture-only-password',
      );
      await tester.pumpWidget(MaterialApp(home: Workbench(repository: repo)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '新建主机'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('选择私钥'));
      await tester.tap(find.text('选择私钥'));
      debugPrint('SALP_PICKER_AWAIT_CANCEL');
      await tester.pump(const Duration(seconds: 8));
      expect(
        repo.locked,
        false,
        reason: 'An app-owned document picker must not be treated as OS lock',
      );
      expect(find.text('保存主机'), findsOneWidget);
      await tester.tap(find.text('选择私钥'));
      await tester.pump(const Duration(seconds: 1));
      expect(repo.locked, false);
      debugPrint('SALP_PICKER_AWAIT_SCREEN_LOCK');
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!repo.locked && DateTime.now().isBefore(deadline)) {
        // Android stops scheduling frames while the screen is off. Poll state
        // without requesting a frame until the controller wakes the device.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(repo.locked, true);
      debugPrint('SALP_PICKER_SCREEN_LOCKED');
      await Future<void>.delayed(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        repo.locked,
        true,
        reason: 'System unlock must not bypass the app password',
      );
      expect(find.widgetWithText(FilledButton, '解锁'), findsOneWidget);
      debugPrint('SALP_PICKER_LOCK_PASSED');
      await tester.pumpWidget(const SizedBox());
      await directory.delete(recursive: true);
    },
  );
}
