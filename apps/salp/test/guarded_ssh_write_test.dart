import 'dart:typed_data';

import 'package:dartssh2/src/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'input waiting for SSH window is cancelled on lock without later replay',
    () async {
      var valid = true;
      final sent = <Object>[];
      final controller = SSHChannelController(
        localId: 0,
        localMaximumPacketSize: 32768,
        localInitialWindowSize: 65536,
        remoteId: 1,
        remoteInitialWindowSize: 0,
        remoteMaximumPacketSize: 32768,
        sendMessage: sent.add,
      );
      final pending = controller.channel.writeGuarded(
        Uint8List.fromList([1, 2, 3]),
        () {
          if (!valid) throw StateError('locked');
        },
      );
      valid = false;
      await expectLater(pending, throwsStateError);
      expect(sent, isEmpty);
      controller.channel.destroy();
    },
  );
}
