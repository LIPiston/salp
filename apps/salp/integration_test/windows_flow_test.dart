import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/connection.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/serial.dart';
import 'package:salp/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows native vault persistence, UI and gated PowerShell PTY', (
    tester,
  ) async {
    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), true);
    }

    app.main();
    await until(() => find.text('连接到你的工作现场').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '新建主机'));
    await tester.pumpAndSettle();
    Finder field(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label,
    );
    await tester.enterText(field('名称'), 'Windows fixture');
    await tester.enterText(field('地址'), 'fixture.invalid');
    await tester.enterText(field('密码'), 'windows-fixture-only-secret');
    await tester.tap(find.text('保存主机'));
    await until(() => find.text('保存主机').evaluate().isEmpty);
    final reopened = await Repository.open();
    expect(reopened.hosts.single.name, 'Windows fixture');
    expect(
      reopened.credentials.values.single.password,
      'windows-fixture-only-secret',
    );
    final bytes = await File('${reopened.directory.path}/vault.salp')
        .readAsBytes();
    expect(
      latin1.decode(bytes),
      isNot(contains('windows-fixture-only-secret')),
    );
    expect(SerialConnection.listPorts(), isA<List<String>>());

    final session = TerminalSession('Windows PTY fixture');
    final marker = File('${reopened.directory.path}/pty-executed');
    final blocked = File('${reopened.directory.path}/pty-blocked');
    String literal(String path) => "'${path.replaceAll("'", "''")}'";
    try {
      await session.openLocal();
      expect(session.connected, true, reason: session.error);
      session.terminal.resize(113, 37);
      // Do not race interactive PowerShell startup with its first input.
      await until(
        () =>
            session.terminal.buffer.getText().contains('PS ') ||
            !session.connected,
      );
      expect(
        session.connected,
        true,
        reason: session.terminal.buffer.getText(),
      );
      session.setLocked(true);
      await session.send(
        "[IO.File]::WriteAllText(${literal(blocked.path)}, 'unexpected')\r",
      );
      session.setLocked(false);
      // Concatenate two pieces: echoed command text cannot satisfy the marker.
      await session.send(
        "[IO.File]::WriteAllText(${literal(marker.path)}, ('SALP_' + 'EXECUTED'))\r",
      );
      try {
        await until(marker.existsSync);
      } catch (_) {
        // Only this ephemeral CI terminal contains test commands. Capture the
        // real ConPTY output to diagnose startup/input instead of guessing.
        debugPrint(
          'SALP_PTY_STATE: ${session.status}; connected=${session.connected}; error=${session.error}',
        );
        debugPrint(
          'SALP_PTY_OUTPUT: ${jsonEncode(session.terminal.buffer.getText())}',
        );
        rethrow;
      }
      expect(await marker.readAsString(), 'SALP_EXECUTED');
      expect(await blocked.exists(), false);
    } finally {
      await session.close();
    }
    expect(session.connected, false);
  }, skip: !Platform.isWindows);
}
