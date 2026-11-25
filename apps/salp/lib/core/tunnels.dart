import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class Tunnel extends ChangeNotifier {
  Tunnel(this.description, this._stop);
  final String description;
  final Future<void> Function() _stop;
  bool active = true;
  Future<void> close() async {
    await _stop();
    active = false;
    notifyListeners();
  }

  static Future<Tunnel> local(
    SSHClient ssh,
    int listenPort,
    String target,
    int port,
  ) async {
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      listenPort,
    );
    final sockets = <Socket>[];
    final channels = <SSHForwardChannel>[];
    final sub = server.listen((socket) async {
      sockets.add(socket);
      try {
        final channel = await ssh.forwardLocal(target, port);
        channels.add(channel);
        unawaited(
          channel.stream.cast<List<int>>().pipe(socket).catchError((_) {
            socket.destroy();
            return socket;
          }),
        );
        unawaited(
          socket.cast<List<int>>().pipe(channel.sink).catchError((_) {}),
        );
      } catch (_) {
        socket.destroy();
      }
    });
    return Tunnel('127.0.0.1:${server.port} → $target:$port', () async {
      await sub.cancel();
      await server.close();
      for (final s in sockets) {
        s.destroy();
      }
      for (final c in channels) {
        // The local listener and sockets are already destroyed. A channel close
        // handshake may wait for a dead peer; destroy is the bounded shutdown.
        c.destroy();
      }
    });
  }

  static Future<Tunnel> remote(
    SSHClient ssh,
    int listenPort,
    String target,
    int port,
  ) async {
    final forward = await ssh.forwardRemote(
      host: '127.0.0.1',
      port: listenPort,
    );
    if (forward == null) throw StateError('服务器拒绝远端转发');
    final sockets = <Socket>[];
    final sub = forward.connections.listen((channel) async {
      try {
        final socket = await Socket.connect(
          target,
          port,
          timeout: const Duration(seconds: 10),
        );
        sockets.add(socket);
        unawaited(
          channel.stream.cast<List<int>>().pipe(socket).catchError((_) {
            socket.destroy();
            return socket;
          }),
        );
        unawaited(
          socket.cast<List<int>>().pipe(channel.sink).catchError((_) {}),
        );
      } catch (_) {
        await channel.close();
      }
    });
    return Tunnel('远端 127.0.0.1:${forward.port} → $target:$port', () async {
      await ssh.cancelForwardRemote(forward);
      await sub.cancel();
      for (final s in sockets) {
        s.destroy();
      }
    });
  }

  static Future<Tunnel> dynamic(SSHClient ssh, int port) async {
    final forward = await ssh.forwardDynamic(
      bindHost: '127.0.0.1',
      bindPort: port,
    );
    return Tunnel('SOCKS5 · 127.0.0.1:${forward.port}', forward.close);
  }
}
