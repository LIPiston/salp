import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host.dart';
import 'package:salp/core/repository.dart';
import 'package:salp/core/vnc.dart';

void main() {
  test('VNC negotiates RFB, renders exact pixels, sends input and rejects input after lock', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = Completer<void>();
    final pixelsReady = Completer<void>();
    final inputs = <List<int>>[];
    Socket? peer;
    listener.listen((socket) async {
      peer = socket;
      final iterator = StreamIterator<int>(socket.expand((b) => b));
      Future<List<int>> read(int n) async {
        final bytes = <int>[];
        for (var i = 0; i < n; i++) {
          if (!await iterator.moveNext()) throw StateError('EOF');
          bytes.add(iterator.current);
        }
        return bytes;
      }

      try {
        socket.add(ascii.encode('RFB 003.008\n'));
        expect(ascii.decode(await read(12)), 'RFB 003.008\n');
        socket.add([1, 1]);
        expect(await read(1), [1]);
        socket.add([0, 0, 0, 0]);
        expect(await read(1), [1]);
        socket.add([
          0,
          2,
          0,
          1,
          32,
          24,
          0,
          1,
          0,
          255,
          0,
          255,
          0,
          255,
          16,
          8,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          4,
          ...ascii.encode('test'),
        ]);
        expect((await read(20)).first, 0);
        final enc = await read(4);
        expect(enc.first, 2);
        await read(((enc[2] << 8) | enc[3]) * 4);
        expect((await read(10)).first, 3);
        socket.add([
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          2,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          255,
          0,
          0,
          255,
          0,
          0,
        ]);
        await socket.flush();
        pixelsReady.complete();
        while (await iterator.moveNext()) {
          final type = iterator.current;
          final rest = await read(
            type == 3
                ? 9
                : type == 4
                ? 7
                : 5,
          );
          if (type != 3) inputs.add([type, ...rest]);
        }
        serverDone.complete();
      } catch (e, st) {
        if (!serverDone.isCompleted) serverDone.completeError(e, st);
      } finally {
        await iterator.cancel();
      }
    });
    final repo = Repository(Directory.systemTemp, Uint8List(32));
    final session = VncSession(
      Host(
        id: 'vnc',
        name: 'VNC fixture',
        address: '127.0.0.1',
        port: listener.port,
        protocol: Protocol.vnc,
      ),
    );
    try {
      await session.open(repo, (_, _, _, _) async => false, (_) async => null);
      await pixelsReady.future;
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (session.frame == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.connected, true, reason: session.error);
      expect(session.frame, [255, 0, 0, 255, 0, 255, 0, 255]);
      session.key(0x61, true);
      session.key(0x61, false);
      session.pointer(1, 0, 1);
      session.setLocked(true);
      session.key(0x62, true);
      session.pointer(0, 0, 0);
      // Wait for the peer to consume the wire data, not a scheduler-dependent
      // 30 ms interval. Closing and awaiting EOF also catches any extra input.
      final inputDeadline = DateTime.now().add(const Duration(seconds: 3));
      while (inputs.length < 3 && DateTime.now().isBefore(inputDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await session.close();
      await serverDone.future.timeout(const Duration(seconds: 3));
      expect(inputs, [
        [4, 1, 0, 0, 0, 0, 0, 97],
        [4, 0, 0, 0, 0, 0, 0, 97],
        [5, 1, 0, 1, 0, 0],
      ]);
      await session.close();
      await serverDone.future.timeout(const Duration(seconds: 3));
    } finally {
      await session.close();
      peer?.destroy();
      await listener.close();
    }
  });
}
