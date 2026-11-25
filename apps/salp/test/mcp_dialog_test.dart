import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/connection.dart';
import 'package:salp/core/mcp.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/ui/mcp_dialog.dart';

void main() {
  testWidgets('declining nonloopback warning leaves MCP stopped', (
    tester,
  ) async {
    final repo = Repository(Directory.systemTemp, Uint8List(32));
    final server = McpServer(
      repo,
      approve: (_) async => false,
      openSession: (h, t) async => TerminalSession(t, host: h),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: McpDialog(repository: repo, server: server),
        ),
      ),
    );
    final address = find.widgetWithText(TextField, '监听 IP');
    expect(address, findsOneWidget);
    await tester.enterText(address, '0.0.0.0');
    await tester.enterText(
      find.widgetWithText(TextField, '允许访问的主机名或 IP'),
      '127.0.0.1',
    );
    await tester.ensureVisible(find.text('启动 MCP'));
    await tester.tap(find.text('启动 MCP'));
    await tester.pumpAndSettle();
    expect(find.text('允许非回环明文监听？'), findsOneWidget);
    expect(server.running, false);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('允许非回环明文监听？'), findsNothing);
    expect(server.running, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
