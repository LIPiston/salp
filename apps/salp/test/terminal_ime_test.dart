import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets(
    'cumulative native text deltas emit each character once and commit IME text only once',
    (tester) async {
      final terminal = Terminal();
      final output = StringBuffer();
      terminal.onOutput = output.write;
      await tester.pumpWidget(
        MaterialApp(home: TerminalView(terminal, autofocus: true)),
      );
      await tester.pump();
      final client = tester.testTextInput.log
          .lastWhere((c) => c.method == 'TextInput.setClient')
          .arguments[0];
      Future<void> delta(
        String old,
        String inserted,
        int start,
        int end,
        int cursor, {
        int composingStart = -1,
        int composingEnd = -1,
      }) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/textinput',
          const JSONMethodCodec().encodeMethodCall(
            MethodCall('TextInputClient.updateEditingStateWithDeltas', [
              client,
              {
                'deltas': [
                  {
                    'oldText': old,
                    'deltaText': inserted,
                    'deltaStart': start,
                    'deltaEnd': end,
                    'selectionBase': cursor,
                    'selectionExtent': cursor,
                    'selectionAffinity': 'TextAffinity.downstream',
                    'selectionIsDirectional': false,
                    'composingBase': composingStart,
                    'composingExtent': composingEnd,
                  },
                ],
              },
            ]),
          ),
          (_) {},
        );
      }

      // The native platform may send multiple queued edits before our reset arrives.
      await delta('', 'p', 0, 0, 1);
      await delta('p', 'r', 1, 1, 2);
      await delta('pr', 'i', 2, 2, 3);
      expect(output.toString(), 'pri');
      await delta('', 'zhong', 0, 0, 5, composingStart: 0, composingEnd: 5);
      expect(output.toString(), 'pri');
      await delta('zhong', '中', 0, 5, 1);
      expect(output.toString(), 'pri中');
      await delta('', 'wen', 0, 0, 3, composingStart: 0, composingEnd: 3);
      await delta('wen', '文', 0, 3, 1, composingStart: 0, composingEnd: 1);
      // Composition ends with a selection update, with no inserted delta.
      await delta('文', '', -1, -1, 1);
      expect(output.toString(), 'pri中文');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
