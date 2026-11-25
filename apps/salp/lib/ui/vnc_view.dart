import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/ui.dart';

import '../core/vnc.dart';

class VncView extends StatefulWidget {
  const VncView({super.key, required this.session});
  final VncSession session;
  @override
  State<VncView> createState() => _VncViewState();
}

class _VncViewState extends State<VncView> {
  final focus = FocusNode();
  final textEdit = GlobalKey<CustomTextEditState>();
  bool keyboardShown = false;
  String? composing;
  ui.Image? image;
  Object? lastFrame;
  int imageGeneration = 0;
  final pressed = <PhysicalKeyboardKey, int>{};
  @override
  void initState() {
    super.initState();
    widget.session.addListener(update);
    update();
  }

  void update() {
    if (widget.session.locked ||
        widget.session.closed ||
        !widget.session.connected) {
      keyboardShown = false;
      composing = null;
      pressed.clear();
      focus.unfocus();
    }
    final frame = widget.session.frame;
    if (frame != null && frame != lastFrame) {
      lastFrame = frame;
      final generation = ++imageGeneration;
      ui.decodeImageFromPixels(
        frame,
        widget.session.width,
        widget.session.height,
        ui.PixelFormat.rgba8888,
        (next) {
          if (!mounted || generation != imageGeneration) {
            next.dispose();
            return;
          }
          setState(() {
            image?.dispose();
            image = next;
          });
        },
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(update);
    releaseKeys();
    focus.dispose();
    image?.dispose();
    super.dispose();
  }

  int? keysym(KeyEvent event) {
    final key = event.logicalKey;
    final special = <LogicalKeyboardKey, int>{
      LogicalKeyboardKey.enter: 0xff0d,
      LogicalKeyboardKey.numpadEnter: 0xff0d,
      LogicalKeyboardKey.escape: 0xff1b,
      LogicalKeyboardKey.backspace: 0xff08,
      LogicalKeyboardKey.tab: 0xff09,
      LogicalKeyboardKey.delete: 0xffff,
      LogicalKeyboardKey.insert: 0xff63,
      LogicalKeyboardKey.home: 0xff50,
      LogicalKeyboardKey.end: 0xff57,
      LogicalKeyboardKey.pageUp: 0xff55,
      LogicalKeyboardKey.pageDown: 0xff56,
      LogicalKeyboardKey.arrowLeft: 0xff51,
      LogicalKeyboardKey.arrowUp: 0xff52,
      LogicalKeyboardKey.arrowRight: 0xff53,
      LogicalKeyboardKey.arrowDown: 0xff54,
      LogicalKeyboardKey.shiftLeft: 0xffe1,
      LogicalKeyboardKey.shiftRight: 0xffe2,
      LogicalKeyboardKey.controlLeft: 0xffe3,
      LogicalKeyboardKey.controlRight: 0xffe4,
      LogicalKeyboardKey.altLeft: 0xffe9,
      LogicalKeyboardKey.altRight: 0xffea,
      LogicalKeyboardKey.metaLeft: 0xffeb,
      LogicalKeyboardKey.metaRight: 0xffec,
    };
    if (special.containsKey(key)) return special[key];
    final functionKeys = [
      LogicalKeyboardKey.f1,
      LogicalKeyboardKey.f2,
      LogicalKeyboardKey.f3,
      LogicalKeyboardKey.f4,
      LogicalKeyboardKey.f5,
      LogicalKeyboardKey.f6,
      LogicalKeyboardKey.f7,
      LogicalKeyboardKey.f8,
      LogicalKeyboardKey.f9,
      LogicalKeyboardKey.f10,
      LogicalKeyboardKey.f11,
      LogicalKeyboardKey.f12,
    ];
    final fn = functionKeys.indexOf(key);
    if (fn >= 0) return 0xffbe + fn;
    final text = event.character ?? key.keyLabel;
    if (text.runes.length != 1) return null;
    final value = text.runes.single;
    return value <= 255 ? value : 0x01000000 | value;
  }

  void releaseKeys() {
    for (final symbol in pressed.values) {
      widget.session.key(symbol, false);
    }
    pressed.clear();
  }

  void stroke(int symbol) {
    widget.session.key(symbol, true);
    widget.session.key(symbol, false);
  }

  void insert(String text) {
    if (!keyboardShown || widget.session.locked || !widget.session.connected) {
      return;
    }
    for (final rune in text.runes) {
      stroke(switch (rune) {
        10 || 13 => 0xff0d,
        9 => 0xff09,
        8 || 127 => 0xff08,
        _ => rune <= 255 ? rune : 0x01000000 | rune,
      });
    }
  }

  void toggleKeyboard() {
    if (keyboardShown) {
      textEdit.currentState?.closeKeyboard();
      setState(() {
        keyboardShown = false;
        composing = null;
      });
    } else {
      setState(() => keyboardShown = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && keyboardShown) textEdit.currentState?.requestKeyboard();
      });
    }
  }

  KeyEventResult key(KeyEvent event) {
    if (widget.session.locked || !widget.session.connected) {
      return KeyEventResult.ignored;
    }
    // With an IME attached, printable text must go through its composition
    // channel once; hardware modifiers and navigation remain key events.
    if (keyboardShown &&
        !(event is KeyUpEvent && pressed.containsKey(event.physicalKey)) &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        event.logicalKey.keyLabel.runes.length == 1) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      final symbol = pressed.remove(event.physicalKey);
      if (symbol != null) widget.session.key(symbol, false);
    } else {
      final symbol = keysym(event);
      if (symbol == null) return KeyEventResult.ignored;
      pressed[event.physicalKey] = symbol;
      widget.session.key(symbol, true);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return Column(
      children: [
        Container(
          color: const Color(0xff171b20),
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              const Icon(Icons.desktop_windows_outlined, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${session.host.label} · ${session.status}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${session.width}×${session.height}'),
              IconButton(
                tooltip: keyboardShown ? '隐藏键盘' : '显示键盘',
                onPressed: session.connected && !session.locked
                    ? toggleKeyboard
                    : null,
                icon: Icon(
                  keyboardShown ? Icons.keyboard_hide : Icons.keyboard,
                ),
              ),
            ],
          ),
        ),
        if (session.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(session.error!),
          ),
        Expanded(
          child: image == null
              ? Center(child: Text(session.status))
              : Focus(
                  onFocusChange: (focused) {
                    if (!focused) releaseKeys();
                  },
                  child: CustomTextEdit(
                    key: textEdit,
                    focusNode: focus,
                    autofocus: true,
                    readOnly:
                        !keyboardShown || session.locked || !session.connected,
                    inputType: TextInputType.multiline,
                    keyboardAppearance: Brightness.dark,
                    deleteDetection: true,
                    onInsert: insert,
                    onDelete: () => stroke(0xff08),
                    onComposing: (value) {
                      if (mounted) setState(() => composing = value);
                    },
                    onAction: (_) => stroke(0xff0d),
                    onKeyEvent: (_, e) => key(e),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final scale = (constraints.maxWidth / session.width)
                            .clamp(0.0, constraints.maxHeight / session.height);
                        final size = Size(
                          session.width * scale,
                          session.height * scale,
                        );
                        void pointer(PointerEvent event) {
                          focus.requestFocus();
                          var buttons = 0;
                          if (event.buttons & kPrimaryMouseButton != 0) {
                            buttons |= 1;
                          }
                          if (event.buttons & kMiddleMouseButton != 0) {
                            buttons |= 2;
                          }
                          if (event.buttons & kSecondaryMouseButton != 0) {
                            buttons |= 4;
                          }
                          session.pointer(
                            (event.localPosition.dx / scale).floor(),
                            (event.localPosition.dy / scale).floor(),
                            buttons,
                          );
                        }

                        return Center(
                          child: SizedBox.fromSize(
                            size: size,
                            child: Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerDown: pointer,
                              onPointerMove: pointer,
                              onPointerUp: pointer,
                              onPointerCancel: (event) => session.pointer(
                                (event.localPosition.dx / scale).floor(),
                                (event.localPosition.dy / scale).floor(),
                                0,
                              ),
                              onPointerHover: pointer,
                              onPointerSignal: (event) {
                                if (event is PointerScrollEvent) {
                                  final x = (event.localPosition.dx / scale)
                                          .floor(),
                                      y = (event.localPosition.dy / scale)
                                          .floor();
                                  session.pointer(
                                    x,
                                    y,
                                    event.scrollDelta.dy < 0 ? 8 : 16,
                                  );
                                  session.pointer(x, y, 0);
                                }
                              },
                              child: RawImage(
                                image: image,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.low,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
        if (composing != null && composing!.isNotEmpty)
          Text(
            composing!,
            style: const TextStyle(decoration: TextDecoration.underline),
          ),
        if (keyboardShown)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final entry in {
                  'Esc': 0xff1b,
                  'Tab': 0xff09,
                  'Ctrl-C': 0x63,
                  'Ctrl-V': 0x76,
                  '↑': 0xff52,
                  '↓': 0xff54,
                  '←': 0xff51,
                  '→': 0xff53,
                  'Del': 0xffff,
                }.entries)
                  TextButton(
                    onPressed: () {
                      final ctrl = entry.key.startsWith('Ctrl-');
                      if (ctrl) session.key(0xffe3, true);
                      stroke(entry.value);
                      if (ctrl) session.key(0xffe3, false);
                    },
                    child: Text(entry.key),
                  ),
              ],
            ),
          ),
        const Padding(
          padding: EdgeInsets.all(6),
          child: Text('画面按窗口缩放 · 不同步剪贴板或重定向文件', style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}
