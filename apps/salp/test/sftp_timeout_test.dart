import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SFTP data waiting for SSH window cannot be sent after authorization is revoked', () async {
    var valid = true;
    final sent = <SSHMessage>[];
    final channel = SSHChannelController(
      localId: 0,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 65536,
      remoteId: 1,
      remoteInitialWindowSize: 0,
      remoteMaximumPacketSize: 32768,
      sendMessage: sent.add,
    );
    final client = SftpClient(
      channel.channel,
      requestTimeout: const Duration(milliseconds: 500),
      authorize: () {
        if (!valid) throw StateError('revoked');
      },
    );
    valid = false;
    await expectLater(client.stat('/never-send'), throwsStateError);
    expect(sent.whereType<SSH_Message_Channel_Data>(), isEmpty);
    await client.close();
  });
  test('SFTP timeout includes waiting for remote SSH send window', () async {
    final sent = <SSHMessage>[];
    final channel = SSHChannelController(
      localId: 0,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 65536,
      remoteId: 1,
      remoteInitialWindowSize: 9, // Exactly the SFTP INIT packet.
      remoteMaximumPacketSize: 32768,
      sendMessage: sent.add,
    );
    final client = SftpClient(
      channel.channel,
      requestTimeout: const Duration(milliseconds: 80),
      authorize: () {},
    );
    channel.handleMessage(
      SSH_Message_Channel_Data(
        recipientChannel: 0,
        data: Uint8List.fromList([0, 0, 0, 5, 2, 0, 0, 0, 3]),
      ),
    );
    try {
      await expectLater(
        client.stat('/window-blocked').timeout(const Duration(seconds: 1)),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'SFTP timeout',
            contains('SFTP request'),
          ),
        ),
      );
      expect(sent.whereType<SSH_Message_Channel_Data>(), hasLength(1));
    } finally {
      await client.close();
    }
  });

  test('closing an unresponsive SFTP channel completes locally', () async {
    final channel = SSHChannelController(
      localId: 0,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 65536,
      remoteId: 1,
      remoteInitialWindowSize: 65536,
      remoteMaximumPacketSize: 32768,
      sendMessage: (_) {},
    );
    final client = SftpClient(channel.channel);
    try {
      await client.close().timeout(const Duration(milliseconds: 200));
    } finally {
      channel.channel.destroy();
    }
  });

  for (final handshake in [false, true]) {
    test(
      'unresponsive SFTP ${handshake ? 'request' : 'handshake'} terminates pending operations',
      () async {
        final sent = <SSHMessage>[];
        final channel = SSHChannelController(
          localId: 0,
          localMaximumPacketSize: 32768,
          localInitialWindowSize: 65536,
          remoteId: 1,
          remoteInitialWindowSize: 65536,
          remoteMaximumPacketSize: 32768,
          sendMessage: sent.add,
        );
        final client = SftpClient(
          channel.channel,
          requestTimeout: const Duration(milliseconds: 80),
        );
        if (handshake) {
          channel.handleMessage(
            SSH_Message_Channel_Data(
              recipientChannel: 0,
              data: Uint8List.fromList([0, 0, 0, 5, 2, 0, 0, 0, 3]),
            ),
          );
        }
        final first = expectLater(
          client.stat('/never-replies'),
          throwsA(isA<TimeoutException>()),
        );
        final second = expectLater(
          client.stat('/also-pending'),
          throwsA(isA<TimeoutException>()),
        );
        await Future.wait([first, second]).timeout(const Duration(seconds: 2));
        final count = sent.whereType<SSH_Message_Channel_Data>().length;
        await expectLater(
          client.stat('/after-timeout'),
          throwsA(isA<TimeoutException>()),
        );
        expect(sent.whereType<SSH_Message_Channel_Data>().length, count);
        channel.channel.destroy();
      },
    );
  }
}
