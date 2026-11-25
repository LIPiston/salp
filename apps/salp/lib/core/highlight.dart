import 'dart:async';
import 'dart:isolate';

import 'package:xterm/xterm.dart';

class HighlightRule {
  HighlightRule(
    this.pattern,
    this.color, {
    this.regex = false,
    this.wholeLine = false,
  });
  final String pattern;
  final int color;
  final bool regex, wholeLine;
  void validate() {
    if (pattern.isEmpty || pattern.length > 256) {
      throw const FormatException('规则必须为 1–256 个字符');
    }
    if (regex) RegExp(pattern);
  }

  Map<String, dynamic> toJson() => {
    'pattern': pattern,
    'color': color,
    'regex': regex,
    'wholeLine': wholeLine,
  };
  factory HighlightRule.fromJson(Map<String, dynamic> j) => HighlightRule(
    j['pattern'] as String,
    j['color'] as int,
    regex: j['regex'] == true,
    wholeLine: j['wholeLine'] == true,
  );
}

class _Snapshot {
  _Snapshot(this.key, this.text, this.locations, this.foregrounds);
  final String key, text;
  final List<(BufferLine, int)> locations;
  final List<int> foregrounds;
}

class _Cached {
  _Cached(this.snapshot, this.colors);
  final _Snapshot snapshot;
  final List<int?> colors;
}

/// No regex runs on the UI isolate. Paint reads cached foregrounds only and
/// schedules at most 64 bounded logical-line snapshots. Worker timeout disables
/// rules for this session until explicitly updated.
class TerminalHighlighter {
  TerminalHighlighter(this.terminal, List<HighlightRule> rules) {
    update(rules);
    terminal.foregroundOverrides = cached;
  }
  final Terminal terminal;
  List<HighlightRule> _rules = [];
  final _cache = <String, _Cached>{};
  final _pending = <String, _Snapshot>{};
  final _waiters = <String, Completer<void>>{};
  bool _running = false, _disposed = false;
  int _epoch = 0;
  Isolate? _worker;
  String? error;
  void update(List<HighlightRule> rules) {
    if (rules.length > 64) throw const FormatException('最多 64 条规则');
    for (final rule in rules) {
      rule.validate();
    }
    _rules = [...rules];
    _cache.clear();
    _pending.clear();
    error = null;
    _epoch++;
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
    terminal.notifyListeners();
  }

  _Snapshot? _snapshot(Buffer buffer, int row) {
    final lines = buffer.lines;
    if (row < 0 || row >= lines.length) return null;
    var first = row, last = row;
    while (first > 0 && lines[first].isWrapped && row - first < 64) {
      first--;
    }
    while (last + 1 < lines.length &&
        lines[last + 1].isWrapped &&
        last - first < 64) {
      last++;
    }
    if (last - first >= 64) return null;
    final text = StringBuffer(), signature = StringBuffer();
    final locations = <(BufferLine, int)>[], foregrounds = <int>[];
    for (var r = first; r <= last; r++) {
      final line = lines[r];
      signature.write('${identityHashCode(line)}:${line.length}:');
      for (var c = 0; c < line.length; c++) {
        final code = line.getCodePoint(c), width = line.getWidth(c);
        if (code == 0 && width == 0 && c > 0 && line.getWidth(c - 1) == 2) {
          continue;
        }
        final char = code == 0 ? ' ' : String.fromCharCode(code);
        if (text.length + char.length > 16384) return null;
        text.write(char);
        for (var u = 0; u < char.length; u++) {
          locations.add((line, c));
          foregrounds.add(line.getForeground(c));
        }
        signature.write('${line.getForeground(c)},');
      }
    }
    return _Snapshot(
      '${identityHashCode(lines[first])}:${text.toString()}:$signature',
      text.toString(),
      locations,
      foregrounds,
    );
  }

  Map<int, int> cached(Buffer buffer, int row) {
    if (_disposed || error != null || _rules.isEmpty) return {};
    final snapshot = _snapshot(buffer, row);
    if (snapshot == null) return {};
    final entry = _cache[snapshot.key];
    if (entry == null) {
      _schedule(snapshot);
      return {};
    }
    final result = <int, int>{};
    for (var i = 0; i < entry.colors.length; i++) {
      final location = entry.snapshot.locations[i];
      if (identical(location.$1, buffer.lines[row]) &&
          entry.colors[i] != null &&
          entry.snapshot.foregrounds[i] & CellColor.typeMask ==
              CellColor.normal) {
        result[location.$2] = entry.colors[i]!;
      }
    }
    return result;
  }

  Future<Map<int, int>> colors(Buffer buffer, int row) async {
    final snapshot = _snapshot(buffer, row);
    if (snapshot == null || _rules.isEmpty || error != null) return {};
    if (!_cache.containsKey(snapshot.key)) {
      _schedule(snapshot);
      await _waiters[snapshot.key]?.future;
    }
    return cached(buffer, row);
  }

  void _schedule(_Snapshot snapshot) {
    if (_pending.length >= 64 || _waiters.containsKey(snapshot.key)) return;
    _pending[snapshot.key] = snapshot;
    _waiters[snapshot.key] = Completer<void>();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty && !_disposed && error == null) {
        final key = _pending.keys.first, epoch = _epoch;
        final snapshot = _pending.remove(key)!;
        final port = ReceivePort();
        try {
          _worker = await Isolate.spawn(_match, [
            port.sendPort,
            snapshot.text,
            _rules.map((r) => r.toJson()).toList(),
          ]);
          final result = await port.first.timeout(
            const Duration(milliseconds: 250),
          );
          if (epoch != _epoch || _disposed) continue;
          if (result is! List<int?>) throw const FormatException('规则解析失败');
          _cache[key] = _Cached(snapshot, result);
          if (_cache.length > 256) _cache.remove(_cache.keys.first);
        } catch (_) {
          if (!_disposed && epoch == _epoch) {
            error = '规则计算超时或失败，当前会话规则着色已停用；终端继续运行';
            _pending.clear();
          }
        } finally {
          _worker?.kill(priority: Isolate.immediate);
          _worker = null;
          port.close();
          final waiter = _waiters.remove(key);
          if (waiter != null && !waiter.isCompleted) waiter.complete();
          if (!_disposed) terminal.notifyListeners();
        }
      }
    } finally {
      _running = false;
      if (error != null || _disposed) {
        for (final waiter in _waiters.values) {
          if (!waiter.isCompleted) waiter.complete();
        }
        _waiters.clear();
      }
    }
  }

  void dispose() {
    _disposed = true;
    _epoch++;
    _worker?.kill(priority: Isolate.immediate);
    terminal.foregroundOverrides = null;
    _pending.clear();
    _cache.clear();
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }
}

void _match(List<Object> request) {
  final port = request[0] as SendPort, text = request[1] as String;
  final colors = List<int?>.filled(text.length, null);
  var matches = 0;
  for (final value in request[2] as List) {
    final rule = HighlightRule.fromJson(
      Map<String, dynamic>.from(value as Map),
    );
    final pattern = rule.regex
        ? RegExp(rule.pattern)
        : RegExp(RegExp.escape(rule.pattern));
    for (final match in pattern.allMatches(text)) {
      if (++matches > 2048) break;
      if (match.start == match.end) continue;
      final start = rule.wholeLine ? 0 : match.start,
          end = rule.wholeLine ? text.length : match.end;
      for (var i = start; i < end; i++) {
        colors[i] ??= rule.color;
      }
      if (rule.wholeLine) break;
    }
    if (matches > 2048) break;
  }
  port.send(colors);
}
