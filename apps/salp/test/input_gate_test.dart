import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/input_gate.dart';

void main() {
  test(
    'external approval is checked again after transport backpressure',
    () async {
      final ready = Completer<void>(), resume = Completer<void>();
      var valid = true;
      final received = <int>[];
      final gate = InputGate.guarded((bytes, check) async {
        ready.complete();
        await resume.future;
        check();
        received.addAll(bytes);
      });
      final pending = gate.send(
        Uint8List.fromList([1, 2]),
        0,
        authorize: () {
          if (!valid) throw StateError('revoked');
        },
      );
      await ready.future;
      final rejected = expectLater(pending, throwsStateError);
      valid = false;
      resume.complete();
      await rejected;
      expect(received, isEmpty);
    },
  );

  test(
    'input preserves byte order including UTF-8 and control bytes',
    () async {
      final received = <int>[];
      final gate = InputGate((bytes) async {
        received.addAll(bytes);
      });
      await Future.wait([
        gate.send(Uint8List.fromList([0xe4, 0xb8, 0xad]), 0),
        gate.send(Uint8List.fromList([3, 13, 0]), 0),
      ]);
      expect(received, [0xe4, 0xb8, 0xad, 3, 13, 0]);
    },
  );
  test(
    'lock invalidates queued input and unlock accepts only new input',
    () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      final received = <int>[];
      final gate = InputGate((bytes) async {
        received.addAll(bytes);
        if (!started.isCompleted) {
          started.complete();
          await finish.future;
        }
      });
      final first = gate.send(Uint8List.fromList([1]), 0);
      await started.future;
      final queued = gate.send(Uint8List.fromList([2]), 0);
      final rejected = expectLater(queued, throwsStateError);
      gate.lock();
      gate.unlock();
      finish.complete();
      await first;
      await rejected;
      await expectLater(
        gate.send(Uint8List.fromList([3]), 0),
        throwsStateError,
      );
      await gate.send(Uint8List.fromList([4]), gate.generation);
      expect(received, [1, 4]);
    },
  );
  test(
    'capacity rejects whole input without truncating or leaking bytes',
    () async {
      final finish = Completer<void>();
      final gate = InputGate((bytes) => finish.future, capacity: 4);
      final first = gate.send(Uint8List.fromList([1, 2, 3]), 0);
      await expectLater(
        gate.send(Uint8List.fromList([4, 5]), 0),
        throwsStateError,
      );
      finish.complete();
      await first;
    },
  );
}
