import 'dart:io';
import 'dart:typed_data';

import 'package:salp/core/repository.dart';
import 'package:salp/core/connection.dart';
import 'package:salp/core/host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/highlight.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('host highlight overrides persist, stay isolated and can inherit global rules again', () async {
    final dir = await Directory.systemTemp.createTemp('salp-highlight-host-');
    final repo = Repository(dir, Uint8List(32));
    final one = TerminalSession(
      'one',
      host: Host(id: 'one', name: 'one', address: 'one.test'),
    );
    final other = TerminalSession(
      'other',
      host: Host(id: 'other', name: 'other', address: 'other.test'),
    );
    try {
      repo.highlightRules = [
        {'pattern': 'GLOBAL', 'color': 0xff00ff00},
      ];
      repo.hostHighlight['one'] = {
        'enabled': true,
        'rules': [
          {'pattern': 'LOCAL', 'color': 0xffff0000},
        ],
      };
      await repo.save();
      final reopened = Repository(dir, Uint8List(32));
      await reopened.load();
      one.terminal.write('GLOBAL LOCAL');
      other.terminal.write('GLOBAL LOCAL');
      one.configureHighlight(reopened);
      other.configureHighlight(reopened);
      await one.highlighter!.colors(one.terminal.buffer, 0);
      await other.highlighter!.colors(other.terminal.buffer, 0);
      expect(one.highlighter!.cached(one.terminal.buffer, 0).keys, [
        7,
        8,
        9,
        10,
        11,
      ]);
      expect(other.highlighter!.cached(other.terminal.buffer, 0).keys, [
        0,
        1,
        2,
        3,
        4,
        5,
      ]);
      reopened.hostHighlight.remove('one');
      one.configureHighlight(reopened);
      await one.highlighter!.colors(one.terminal.buffer, 0);
      expect(one.highlighter!.cached(one.terminal.buffer, 0).keys, [
        0,
        1,
        2,
        3,
        4,
        5,
      ]);
    } finally {
      await one.close();
      await other.close();
      await dir.delete(recursive: true);
    }
  });

  test('highlights fragmented wrapped Unicode text without mutating ANSI or terminal state', () async {
    final terminal = Terminal()..resize(6, 8);
    final highlighter = TerminalHighlighter(terminal, [
      HighlightRule('ERR.*R', 0xffcc0000, regex: true),
    ]);
    try {
      terminal.write('中ERR');
      terminal.write('OR\r\n\x1b[32mERROR\x1b[0m');
      final before = terminal.buffer.getText();
      final x = terminal.buffer.cursorX, y = terminal.buffer.cursorY;
      await highlighter.colors(terminal.buffer, 0);
      expect(
        highlighter.cached(terminal.buffer, 0).keys,
        containsAll([2, 3, 4, 5]),
      );
      expect(highlighter.cached(terminal.buffer, 1).keys, contains(0));
      expect(terminal.buffer.getText(), before);
      expect(terminal.buffer.cursorX, x);
      expect(terminal.buffer.cursorY, y);
      await highlighter.colors(terminal.buffer, 2);
      expect(highlighter.cached(terminal.buffer, 2), isEmpty);
      terminal.write('\r\x1b[0mOK\x1b[K');
      await highlighter.colors(terminal.buffer, 2);
      expect(highlighter.cached(terminal.buffer, 2), isEmpty);
    } finally {
      highlighter.dispose();
    }
  });
  test(
    'bad regex reports an error and slow regex is bounded by worker timeout',
    () async {
      expect(
        () => HighlightRule('[', 0xff000000, regex: true).validate(),
        throwsFormatException,
      );
      final terminal = Terminal()
        ..resize(1200, 2)
        ..write('${'a' * 1000}!');
      final highlighter = TerminalHighlighter(terminal, [
        HighlightRule('(a+)+\$', 0xff000000, regex: true),
      ]);
      try {
        await highlighter
            .colors(terminal.buffer, 0)
            .timeout(const Duration(seconds: 2));
        expect(highlighter.error, isNotNull);
        expect(terminal.buffer.getText(), contains('!'));
      } finally {
        highlighter.dispose();
      }
    },
  );
}
