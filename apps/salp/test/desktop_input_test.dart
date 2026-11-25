import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/vnc.dart';
import 'package:salp/ui/vnc_view.dart';

// Observe the view's protocol boundary; actual RFB/RDP transport has its own
// loopback integration fixtures. Never send input to a real user's desktop.
class InputSession extends VncSession {
  InputSession()
    : super(Host(id: 'input', name: 'fixture', address: 'localhost')) {
    connected = true;
    width = 2;
    height = 1;
    frame = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]);
  }
  final keys = <(int, bool)>[];
  @override
  void setLocked(bool value) {
    locked = value;
    notifyListeners();
  }

  @override
  void key(int keysym, bool down) {
    if (connected && !closed && !locked) keys.add((keysym, down));
  }
}

void main() {
  testWidgets(
    'remote desktop keyboard sends committed IME once, handles special keys and discards composition on lock',
    (tester) async {
      final session = InputSession();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VncView(session: session)),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('显示键盘'));
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  zhong',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 2, end: 7),
        ),
      );
      expect(session.keys, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  中',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      expect(session.keys, [(0x01004e2d, true), (0x01004e2d, false)]);
      session.keys.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(session.keys, [(0xff0d, true), (0xff0d, false)]);
      session.keys.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      expect(session.keys, [
        (0xffe3, true),
        (0x63, true),
        (0xffe3, false),
        (0x63, false),
      ]);
      session.keys.clear();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  wen',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 2, end: 5),
        ),
      );
      session.setLocked(true);
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      session.setLocked(false);
      await tester.pump();
      expect(session.keys, isEmpty);
      await tester.tap(find.byTooltip('显示键盘'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(session.keys, [(0xff0d, true), (0xff0d, false)]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
