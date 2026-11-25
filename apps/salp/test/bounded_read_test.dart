import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/bounded_read.dart';

void main() {
  test('bounded file reads stop consuming before the oversized input can accumulate', () async {
    var reads = 0;
    Stream<List<int>> chunks() async* {
      reads++;
      yield [1, 2];
      reads++;
      yield [3, 4, 5];
      reads++;
      yield [6];
    }

    await expectLater(
      readBounded(chunks(), maxBytes: 4, authorize: () {}),
      throwsFormatException,
    );
    expect(reads, 2);
  });
  test(
    'revoked picker read never returns buffered credentials after unlock',
    () async {
      var generation = 1;
      Stream<List<int>> chunks() async* {
        yield [1, 2];
        generation += 2;
        yield [3];
      }

      await expectLater(
        readBounded(
          chunks(),
          maxBytes: 10,
          authorize: () {
            if (generation != 1) throw StateError('authority changed');
          },
        ),
        throwsStateError,
      );
      expect(
        await readBounded(
          Stream.fromIterable([
            [0xe4],
            [0xb8, 0xad],
          ]),
          maxBytes: 3,
          authorize: () {},
        ),
        [0xe4, 0xb8, 0xad],
      );
    },
  );
}
