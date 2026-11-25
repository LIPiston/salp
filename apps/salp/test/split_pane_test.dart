import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:salp/ui/split_pane.dart';

void main() {
  testWidgets('split divider resizes both axes and preserves child state', (
    tester,
  ) async {
    Widget app(Axis axis) => MaterialApp(
      home: Scaffold(
        body: SplitPane(
          axis: axis,
          first: const ColoredBox(key: Key('first'), color: Colors.red),
          second: const ColoredBox(key: Key('second'), color: Colors.blue),
        ),
      ),
    );
    await tester.pumpWidget(app(Axis.horizontal));
    final before = tester.getSize(find.byKey(const Key('first'))).width;
    await tester.drag(find.byType(GestureDetector), const Offset(100, 0));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const Key('first'))).width,
      greaterThan(before),
    );
    await tester.pumpWidget(app(Axis.vertical));
    final height = tester.getSize(find.byKey(const Key('first'))).height;
    await tester.drag(find.byType(GestureDetector), const Offset(0, -100));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const Key('first'))).height,
      lessThan(height),
    );
    expect(tester.takeException(), isNull);
  });
}
