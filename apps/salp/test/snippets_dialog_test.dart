import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/connection.dart';
import 'package:salp/ui/snippets_dialog.dart';

void main() {
  testWidgets(
    'snippet groups filter saved entries and selection previews exact content',
    (tester) async {
      final repo = Repository(Directory.systemTemp, Uint8List(32));
      repo.snippets.addAll({
        '维护 / 磁盘': 'df -h\n',
        '部署 / 重启': 'systemctl restart example\n',
        '独立片段': 'uptime',
      });
      final session = TerminalSession('fixture');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SnippetsDialog(repository: repo, session: session),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '维护'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ActionChip, '维护 / 磁盘'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '部署 / 重启'), findsNothing);
      await tester.tap(find.widgetWithText(ActionChip, '维护 / 磁盘'));
      await tester.pumpAndSettle();
      final editor = tester.widget<TextField>(
        find.widgetWithText(TextField, '发送前预览并编辑内容'),
      );
      expect(editor.controller!.text, 'df -h\n');
      await tester.tap(find.widgetWithText(ChoiceChip, '未分组'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ActionChip, '独立片段'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '维护 / 磁盘'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await session.close();
    },
  );
}
