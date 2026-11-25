import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/connection.dart';
import 'package:salp/core/host.dart';

void main() {
  test(
    'unlock renders buffered output without replaying terminal response input',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final listener = server.listen(accepted.complete);
      final session = TerminalSession(
        'telnet',
        host: Host(
          id: 'one',
          name: 'local',
          address: '127.0.0.1',
          port: server.port,
          protocol: Protocol.telnet,
        ),
      );
      Socket? peer;
      try {
        await session.openTelnet();
        peer = await accepted.future;
        final received = <int>[];
        peer.listen(received.addAll);
        session.setLocked(true);
        peer.add(utf8.encode('hidden\x1b[6n'));
        await peer.flush();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(received, isEmpty);
        session.setLocked(false);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(received, isEmpty);
        await session.send('fresh');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(utf8.decode(received), 'fresh');
      } finally {
        await session.close();
        peer?.destroy();
        await listener.cancel();
        await server.close();
      }
    },
  );

  test('locked or closed session cannot start a new connection', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var count = 0;
    final listener = server.listen((s) {
      count++;
      s.destroy();
    });
    final session = TerminalSession(
      'telnet',
      host: Host(
        id: 'one',
        name: 'local',
        address: '127.0.0.1',
        port: server.port,
        protocol: Protocol.telnet,
      ),
    );
    try {
      session.setLocked(true);
      await session.openTelnet();
      expect(session.connected, false);
      expect(count, 0);
      await session.close();
      await session.openTelnet();
      expect(count, 0);
    } finally {
      await session.close();
      await listener.cancel();
      await server.close();
    }
  });
}
