import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/ui/serial_dialog.dart';

void main() {
  testWidgets(
    'saved serial profile populates all controls without opening hardware',
    (tester) async {
      final repo = Repository(Directory.systemTemp, Uint8List(32));
      repo.serialProfiles['router'] = {
        'path': '/dev/fixture-serial',
        'baud': 9600,
        'bits': 7,
        'stopBits': 2,
        'parity': 2,
        'flow': 1,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SerialDialog(repository: repo)),
        ),
      );
      await tester.tap(find.text('载入：router'));
      await tester.pumpAndSettle();
      String value(String label) => tester
          .widget<TextField>(find.widgetWithText(TextField, label))
          .controller!
          .text;
      expect(value('设备路径'), '/dev/fixture-serial');
      expect(value('波特率'), '9600');
      expect(value('配置名称'), 'router');
      expect(find.text('偶校验'), findsOneWidget);
      expect(find.text('XON/XOFF'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
