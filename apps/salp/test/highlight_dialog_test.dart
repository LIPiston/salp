import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/ui/highlight_dialog.dart';

void main() {
  testWidgets(
    'host highlight inheritance can be disabled without disabling the toggle',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = Repository(Directory.systemTemp, Uint8List(32));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HighlightDialog(repository: repo, hostId: 'fixture'),
          ),
        ),
      );
      final toggle = find.widgetWithText(SwitchListTile, '继承全局规则');
      expect(tester.widget<SwitchListTile>(toggle).value, true);
      final pattern = find.widgetWithText(TextField, '匹配内容或正则');
      expect(tester.widget<TextField>(pattern).enabled, false);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(pattern).enabled, true);
      await tester.enterText(pattern, 'CUSTOM');
      await tester.ensureVisible(find.text('添加并预览'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加并预览'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'CUSTOM'), findsOneWidget);
      expect(tester.widget<TextField>(pattern).controller!.text, isEmpty);
      expect(
        repo.hostHighlight,
        isEmpty,
        reason: 'preview edits remain uncommitted',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
