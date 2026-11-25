import 'package:material_ui/material_ui.dart';

class SplitPane extends StatefulWidget {
  const SplitPane({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
  });
  final Axis axis;
  final Widget first, second;
  @override
  State<SplitPane> createState() => _SplitPaneState();
}

class _SplitPaneState extends State<SplitPane> {
  double ratio = .5;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final horizontal = widget.axis == Axis.horizontal;
      final extent = horizontal ? constraints.maxWidth : constraints.maxHeight;
      void drag(DragUpdateDetails details) => setState(() {
        ratio =
            (ratio +
                    (horizontal ? details.delta.dx : details.delta.dy) / extent)
                .clamp(.2, .8);
      });
      return Flex(
        direction: widget.axis,
        children: [
          Expanded(flex: (ratio * 1000).round(), child: widget.first),
          Semantics(
            label: '拖动调整分屏大小',
            child: MouseRegion(
              cursor: horizontal
                  ? SystemMouseCursors.resizeColumn
                  : SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: horizontal ? drag : null,
                onVerticalDragUpdate: horizontal ? null : drag,
                child: SizedBox(
                  width: horizontal ? 8 : null,
                  height: horizontal ? null : 8,
                  child: Center(
                    child: Container(
                      width: horizontal ? 1 : null,
                      height: horizontal ? null : 1,
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(flex: ((1 - ratio) * 1000).round(), child: widget.second),
        ],
      );
    },
  );
}
