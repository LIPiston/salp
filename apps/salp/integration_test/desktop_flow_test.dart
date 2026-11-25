import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import 'package:salp/main.dart' as app;
import 'package:salp/core/repository.dart';
import 'package:salp/core/master_password.dart';
import 'package:salp/ui/workbench.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
          .shouldPropagateDevicePointerEvents =
      true;
  testWidgets(
    'native startup, secure credentials, restart and keyboard to PTY',
    (tester) async {
      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
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
      await tester.enterText(field('名称'), 'Native fixture');
      await tester.enterText(field('地址'), 'fixture.invalid');
      await tester.enterText(field('密码'), 'fixture-only-not-real-secret');
      await tester.tap(find.text('保存主机'));
      await until(() => find.text('保存主机').evaluate().isEmpty);
      final reopened = await Repository.open();
      expect(reopened.hosts.single.name, 'Native fixture');
      expect(
        reopened.credentials.values.single.password,
        'fixture-only-not-real-secret',
      );
      final bytes = await File('${reopened.directory.path}/vault.salp')
          .readAsBytes();
      expect(
        latin1.decode(bytes),
        isNot(contains('fixture-only-not-real-secret')),
      );

      await tester.tap(find.widgetWithText(ListTile, '本地终端'));
      await until(() => find.byType(TerminalView).evaluate().isNotEmpty);
      final terminalView = find.byType(TerminalView);
      final point = tester.getCenter(terminalView);
      final marker = File('${reopened.directory.path}/native-executed');
      final window = (await Process.run('xdotool', [
        'search',
        '--name',
        r'^salp$',
      ])).stdout.toString().trim().split('\n').first;
      for (final arguments in [
        ['windowfocus', window],
        [
          'mousemove',
          '--window',
          window,
          '${point.dx.round()}',
          '${point.dy.round()}',
          'click',
          '1',
        ],
        [
          'type',
          '--clearmodifiers',
          '--delay',
          '2',
          "printf '%s%s' 'SALP_NATIVE_' 'EXECUTED' > '${marker.path}'",
        ],
        ['key', 'Return'],
      ]) {
        final result = await Process.run('xdotool', arguments);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      await tester.pump(const Duration(seconds: 1));
      await until(marker.existsSync);
      expect(await marker.readAsString(), 'SALP_NATIVE_EXECUTED');
      final notifier = await Process.start('python3', [
        'tool/fixture_screen_lock.py',
      ]);
      final lines = StreamIterator(
        notifier.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        expect(await lines.moveNext(), true);
        expect(lines.current, 'ready');
        notifier.stdin.writeln('lock');
        await notifier.stdin.flush();
        await until(() => find.text('等待系统解锁').evaluate().isNotEmpty);
        expect(find.byType(TerminalView), findsNothing);
        notifier.stdin.writeln('unlock');
        await notifier.stdin.flush();
        await until(() => find.byType(TerminalView).evaluate().isNotEmpty);
      } finally {
        await notifier.stdin.close();
        await notifier.exitCode;
        await lines.cancel();
      }
      await tester.tap(find.widgetWithText(ListTile, 'MCP 代理'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('启动 MCP'));
      await tester.tap(find.text('启动 MCP'));
      await until(() => find.text('停止 MCP 并关闭代理会话').evaluate().isNotEmpty);
      final endpoint = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data ?? '')
          .firstWhere((t) => t.startsWith('http://127.0.0.1:'));
      final http = HttpClient();
      try {
        final request = await http.postUrl(Uri.parse(endpoint));
        request.write(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        );
        final response = await request.close();
        expect(response.statusCode, 401);
        await response.drain<void>();
      } finally {
        http.close(force: true);
      }
      await tester.tap(find.text('停止 MCP 并关闭代理会话'));
      await until(() => find.text('启动 MCP').evaluate().isNotEmpty);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      final active = tester
          .widget<Workbench>(find.byType(Workbench))
          .repository;
      final verifier = await MasterPassword.create('fixture-backup-password');
      final backup = active.syncEntries()
        ..['snippet:restored'] = 'restored fixture secret';
      await active.update((draft) {
        draft.masterPassword = verifier;
        draft.snippets['current'] = 'current fixture secret';
        draft.syncBackup = {'local': backup, 'remote': backup};
      });
      await tester.tap(find.widgetWithText(ListTile, '设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('WebDAV 加密同步'));
      await tester.tap(find.text('WebDAV 加密同步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复同步备份'));
      await tester.pumpAndSettle();
      await tester.enterText(field('当前应用主密码'), 'fixture-backup-password');
      await tester.tap(find.text('替换本地记录'));
      await until(() => find.text('恢复本地备份').evaluate().isEmpty);
      final restored = await Repository.open();
      expect(restored.snippets, {'restored': 'restored fixture secret'});
      expect(
        restored.syncBackup['undo']['snippet:current'],
        'current fixture secret',
      );
      expect(
        restored.credentials.values.single.password,
        'fixture-only-not-real-secret',
      );
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '串口终端'));
      await tester.pumpAndSettle();
      await tester.enterText(field('配置名称'), 'Native serial fixture');
      await tester.enterText(field('设备路径'), '/dev/salp-fixture-only');
      await tester.enterText(field('波特率'), '9600');
      await tester.ensureVisible(find.text('保存当前配置'));
      await tester.tap(find.text('保存当前配置'));
      await until(() => find.text('已保存配置').evaluate().isNotEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final serialRepo = await Repository.open();
      expect(serialRepo.serialProfiles['Native serial fixture']?['baud'], 9600);
      await tester.tap(find.widgetWithText(ListTile, '串口终端'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('载入：Native serial fixture'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('设备路径')).controller!.text,
        '/dev/salp-fixture-only',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('主机操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('此主机着色规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '继承全局规则'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('匹配内容或正则'));
      await tester.enterText(field('匹配内容或正则'), 'NATIVE_CUSTOM');
      await tester.ensureVisible(find.text('添加并预览'));
      await tester.tap(find.text('添加并预览'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存规则'));
      await until(() => find.text('此主机的着色规则').evaluate().isEmpty);
      final highlightRepo = await Repository.open();
      final rules =
          highlightRepo.hostHighlight[highlightRepo.hosts.single.id]!['rules']
              as List;
      expect(rules.last['pattern'], 'NATIVE_CUSTOM');
      // Proof of actual shell execution cannot be satisfied by terminal echo.
      debugPrint(
        'SALP_NATIVE_FLOW: secure-store reopen, encrypted disk, native keyboard to PTY, OS lock/unlock and MCP UI start/auth/stop and encrypted sync backup restore and serial profile save/reload and host highlight save passed',
      );
      final evidence = Platform.environment['SALP_UI_EVIDENCE'];
      if (evidence != null) {
        await Process.run('ffmpeg', [
          '-y',
          '-loglevel',
          'error',
          '-f',
          'x11grab',
          '-draw_mouse',
          '0',
          '-video_size',
          '1280x844',
          '-i',
          Platform.environment['DISPLAY']!,
          '-frames:v',
          '1',
          '$evidence/desktop.png',
        ]);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
