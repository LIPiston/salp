import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// Bounded, ordered input accepted under a specific lock generation.
/// Completion means handed to the local transport, never remote execution.
class InputGate {
  InputGate(Future<void> Function(Uint8List) write, {this.capacity = 65536})
    : write = ((bytes, _) => write(bytes));
  InputGate.guarded(this.write, {this.capacity = 65536});
  final Future<void> Function(Uint8List, void Function()) write;
  final int capacity;
  final _pending = Queue<_Input>();
  bool locked = false;
  bool _running = false;
  bool _closed = false;
  int generation = 0;
  int _bytes = 0;

  Future<void> send(Uint8List bytes, int epoch, {void Function()? authorize}) {
    if (_closed || locked || epoch != generation) {
      return Future.error(StateError('输入上下文已失效，请重新输入'));
    }
    if (_bytes + bytes.length > capacity || _pending.length >= 1024) {
      return Future.error(StateError('输入队列已满，此次输入未接受'));
    }
    final item = _Input(Uint8List.fromList(bytes), epoch, authorize);
    _bytes += bytes.length;
    _pending.add(item);
    unawaited(_drain());
    return item.done.future;
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final item = _pending.removeFirst();
        try {
          void check() {
            if (_closed || locked || item.epoch != generation) {
              throw StateError('输入上下文已失效，请重新输入');
            }
            item.authorize?.call();
          }

          check();
          await write(item.bytes, check).timeout(const Duration(seconds: 10));
          item.done.complete();
        } catch (_) {
          item.done.completeError(StateError('输入状态未知或已失效，请检查终端后重新输入'));
          invalidate();
        } finally {
          _bytes -= item.bytes.length;
        }
      }
    } finally {
      _running = false;
    }
  }

  void invalidate() {
    generation++;
    while (_pending.isNotEmpty) {
      final item = _pending.removeFirst();
      _bytes -= item.bytes.length;
      item.done.completeError(StateError('排队输入已作废，不会重放'));
    }
  }

  void lock() {
    locked = true;
    invalidate();
  }

  void unlock() {
    locked = false;
  }

  void close() {
    _closed = true;
    invalidate();
  }
}

class _Input {
  _Input(this.bytes, this.epoch, this.authorize);
  final void Function()? authorize;
  final Uint8List bytes;
  final int epoch;
  final done = Completer<void>();
}
