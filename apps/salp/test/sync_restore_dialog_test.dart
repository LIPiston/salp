import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/ui/sync_dialog.dart';

void main() {
  testWidgets(
    'sync backup preview hides secrets and cancel preserves current data',
    (tester) async {
      final repo = Repository(Directory.systemTemp, Uint8List(32));
      repo.snippets['current'] = 'current secret';
      repo.syncBackup = {
        'local': {'snippet:old': 'hidden old content'},
        'remote': {'snippet:remote': 'hidden remote content'},
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SyncDialog(repository: repo)),
        ),
      );
      final entry = find.text('恢复同步备份');
      expect(entry, findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('恢复本地备份'), findsOneWidget);
      expect(find.textContaining('新增 1'), findsOneWidget);
      expect(find.textContaining('移除 1'), findsOneWidget);
      expect(find.textContaining('hidden old content'), findsNothing);
      expect(find.textContaining('hidden remote content'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.snippets, {'current': 'current secret'});
      expect(find.text('恢复本地备份'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
