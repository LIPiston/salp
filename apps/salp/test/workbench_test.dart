import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:salp/core/master_password.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/ui/workbench.dart';
import 'package:salp/ui/sync_dialog.dart';

Future<void> osNotification(WidgetTester tester, String method) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'dev.salp/session-lock',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'short desktop window keeps sidebar actions reachable by scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = Repository(Directory.systemTemp, Uint8List(32));
      await tester.pumpWidget(MaterialApp(home: Workbench(repository: repo)));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.widgetWithText(ListTile, '设置'));
      await tester.tap(find.widgetWithText(ListTile, '设置'));
      await tester.pumpAndSettle();
      expect(find.text('第三方许可证'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'OS lock gates the app even with no master password and only OS unlock restores it',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = Repository(Directory.systemTemp, Uint8List(32));
      await tester.pumpWidget(MaterialApp(home: Workbench(repository: repo)));
      final before = repo.epoch;
      await osNotification(tester, 'lock');
      expect(repo.locked, true);
      expect(repo.epoch, greaterThan(before));
      expect(find.text('连接到你的工作现场'), findsNothing);
      expect(find.text('等待系统解锁'), findsOneWidget);
      final lockedEpoch = repo.epoch;
      await osNotification(tester, 'unlock');
      expect(repo.locked, false);
      expect(repo.epoch, greaterThan(lockedEpoch));
      expect(find.text('连接到你的工作现场'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'OS unlock cannot bypass an existing application master password',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = Repository(Directory.systemTemp, Uint8List(32));
      repo.masterPassword = await tester.runAsync(
        () => MasterPassword.create('test-master-password'),
      );
      await tester.pumpWidget(MaterialApp(home: Workbench(repository: repo)));
      await osNotification(tester, 'lock');
      expect(repo.locked, true);
      await osNotification(tester, 'unlock');
      expect(repo.locked, true);
      expect(find.widgetWithText(FilledButton, '解锁'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [1280.0, 390.0]) {
    testWidgets(
      'sync form fits width $width with no hidden password migration field',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = Repository(Directory.systemTemp, Uint8List(32));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SyncDialog(repository: repo)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'HTTPS 文件地址'), findsOneWidget);
        expect(find.widgetWithText(TextField, '远端新主密码（通常留空）'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets('workbench opens and host editor fits width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = Repository(Directory.systemTemp, Uint8List(32));
      await tester.pumpWidget(MaterialApp(home: Workbench(repository: repo)));
      expect(find.text('连接到你的工作现场'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '新建主机'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '地址'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
