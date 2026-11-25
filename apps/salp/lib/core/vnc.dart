import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'connection.dart';
import 'host.dart';
import 'repository.dart';

class _RfbReader {
  _RfbReader(Stream<Uint8List> stream) : iterator = StreamIterator(stream);
  final StreamIterator<Uint8List> iterator;
  Uint8List pending = Uint8List(0);
  int offset = 0;
  Future<Uint8List> read(int count) async {
    if (count < 0 || count > 64 * 1024 * 1024) {
      throw const FormatException('VNC 消息过大');
    }
    final output = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (offset == pending.length) {
        if (!await iterator.moveNext()) throw StateError('VNC 连接已断开');
        pending = iterator.current;
        offset = 0;
      }
      final take = (count - written).clamp(0, pending.length - offset);
      output.setRange(written, written + take, pending, offset);
      offset += take;
      written += take;
    }
    return output;
  }

  Future<int> u32() async => ByteData.sublistView(await read(4)).getUint32(0);
}

Uint8List vncPasswordResponse(String password, Uint8List challenge) {
  if (challenge.length != 16) throw const FormatException('VNC challenge 长度错误');
  final bytes = latin1.encode(password);
  final key = Uint8List(24);
  for (var i = 0; i < 8; i++) {
    var value = i < bytes.length ? bytes[i] : 0, reversed = 0;
    for (var bit = 0; bit < 8; bit++) {
      reversed = (reversed << 1) | (value & 1);
      value >>= 1;
    }
    key[i] = key[8 + i] = key[16 + i] = reversed;
  }
  final cipher = DESedeEngine()..init(true, KeyParameter(key));
  final output = Uint8List(16);
  cipher.processBlock(challenge, 0, output, 0);
  cipher.processBlock(challenge, 8, output, 8);
  key.fillRange(0, key.length, 0);
  return output;
}

class VncSession extends ChangeNotifier {
  VncSession(this.host);
  final Host host;
  SSHSocket? _socket;
  SshConnection? _jump;
  _RfbReader? _reader;
  int width = 0, height = 0;
  Uint8List? frame;
  Uint8List? _pixels;
  bool connected = false, closed = false, locked = false;
  int _epoch = 0;
  String status = '连接中', name = '';
  String? error;

  Future<void> open(
    Repository repo,
    VerifyHost verify,
    PromptAuth prompt,
  ) async {
    final authority = repo.epoch, generation = _epoch;
    void check() {
      repo.checkAuthority(authority);
      if (closed || locked || generation != _epoch) {
        throw StateError('VNC 授权已失效');
      }
    }

    try {
      check();
      host.validate();
      if (host.jumpIds.isEmpty) {
        _socket = await SSHSocket.connect(
          host.address,
          host.port,
          timeout: const Duration(seconds: 15),
        );
      } else {
        final last = repo.host(host.jumpIds.last);
        final jump = Host(
          id: last.id,
          name: last.name,
          address: last.address,
          port: last.port,
          username: last.username,
          jumpIds: host.jumpIds.take(host.jumpIds.length - 1).toList(),
        );
        _jump = await SshConnection.connect(repo, jump, verify, prompt);
        check();
        _socket = await _jump!.client.forwardLocal(host.address, host.port);
      }
      check();
      final reader = _reader = _RfbReader(_socket!.stream);
      await _handshake(
        reader,
        repo.credentials[host.id]?.password ?? '',
        check,
      ).timeout(const Duration(seconds: 20));
      check();
      connected = true;
      status = host.jumpIds.isEmpty ? 'VNC · 直连未加密' : 'VNC · SSH 隧道';
      _requestUpdate(false);
      unawaited(_updates(reader));
    } catch (e) {
      _socket?.destroy();
      await _jump?.close();
      error = e is TrustSaved
          ? e.toString()
          : e is FormatException
          ? e.message
          : 'VNC 连接失败，请检查地址、密码和服务端认证方式';
      status = '连接失败';
    }
    notifyListeners();
  }

  void _dimensions(int w, int h) {
    if (w < 1 || h < 1 || w > 4096 || h > 4096) {
      throw const FormatException('VNC 分辨率超过 4096×4096 上限');
    }
    width = w;
    height = h;
    _pixels = Uint8List(w * h * 4);
  }

  Future<void> _handshake(
    _RfbReader r,
    String password,
    void Function() check,
  ) async {
    final version = ascii.decode(await r.read(12));
    check();
    if (!RegExp(r'^RFB 003\.00[378]\n$').hasMatch(version)) {
      throw const FormatException('仅支持 RFB 3.3/3.7/3.8');
    }
    final minor = int.parse(version.substring(8, 11));
    _send(
      ascii.encode(
        minor >= 8
            ? 'RFB 003.008\n'
            : minor >= 7
            ? 'RFB 003.007\n'
            : 'RFB 003.003\n',
      ),
    );
    int security;
    if (minor == 3) {
      security = await r.u32();
    } else {
      final count = (await r.read(1))[0];
      if (count == 0) throw const FormatException('VNC 服务器拒绝连接');
      final options = await r.read(count);
      security = options.contains(2)
          ? 2
          : options.contains(1)
          ? 1
          : 0;
      if (security == 0) {
        throw const FormatException(
          '服务器需要未支持的 TLS/VeNCrypt 认证，请配置 SSH 跳板与兼容的 VNC 认证',
        );
      }
      check();
      _send([security]);
    }
    check();
    if (security == 2) {
      final challenge = await r.read(16);
      check();
      _send(vncPasswordResponse(password, challenge));
    } else if (security != 1) {
      throw const FormatException('不支持的 VNC 认证方式');
    }
    if (security == 2 || minor >= 8) {
      if (await r.u32() != 0) throw const FormatException('VNC 密码错误或认证失败');
    }
    check();
    _send([1]); // Shared desktop.
    final initial = ByteData.sublistView(await r.read(24));
    _dimensions(initial.getUint16(0), initial.getUint16(2));
    final titleLength = initial.getUint32(20);
    if (titleLength > 65536) throw const FormatException('VNC 桌面名称过长');
    name = utf8.decode(await r.read(titleLength), allowMalformed: true);
    check();
    // Request 32-bit little-endian true colour (B,G,R,pad on the wire).
    _send([
      0,
      0,
      0,
      0,
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
    ]);
    final encodings = ByteData(16)
      ..setUint8(0, 2)
      ..setUint16(2, 3)
      ..setInt32(4, 0)
      ..setInt32(8, 1)
      ..setInt32(12, -223);
    _send(encodings.buffer.asUint8List());
  }

  void _send(List<int> bytes) {
    if (closed) throw StateError('VNC 已关闭');
    _socket!.sink.add(bytes);
  }

  void _requestUpdate(bool incremental) {
    if (locked || closed || !connected) return;
    final request = ByteData(10)
      ..setUint8(0, 3)
      ..setUint8(1, incremental ? 1 : 0)
      ..setUint16(6, width)
      ..setUint16(8, height);
    _send(request.buffer.asUint8List());
  }

  Future<void> _updates(_RfbReader r) async {
    try {
      while (!closed) {
        final type = (await r.read(1))[0];
        if (type == 0) {
          final header = ByteData.sublistView(await r.read(3));
          final count = header.getUint16(1);
          if (count > 4096) throw const FormatException('VNC 矩形过多');
          for (var i = 0; i < count; i++) {
            final rect = ByteData.sublistView(await r.read(12));
            final x = rect.getUint16(0),
                y = rect.getUint16(2),
                w = rect.getUint16(4),
                h = rect.getUint16(6),
                encoding = rect.getInt32(8);
            if (encoding == -223) {
              _dimensions(w, h);
              continue;
            }
            if (x + w > width || y + h > height) {
              throw const FormatException('VNC 矩形越界');
            }
            if (encoding == 0) {
              final raw = await r.read(w * h * 4);
              for (var row = 0; row < h; row++) {
                for (var col = 0; col < w; col++) {
                  final source = (row * w + col) * 4,
                      dest = ((y + row) * width + x + col) * 4;
                  _pixels![dest] = raw[source + 2];
                  _pixels![dest + 1] = raw[source + 1];
                  _pixels![dest + 2] = raw[source];
                  _pixels![dest + 3] = 255;
                }
              }
            } else if (encoding == 1) {
              final source = ByteData.sublistView(await r.read(4));
              final sx = source.getUint16(0), sy = source.getUint16(2);
              if (sx + w > width || sy + h > height) {
                throw const FormatException('VNC 复制区域越界');
              }
              final copy = Uint8List(w * h * 4);
              for (var row = 0; row < h; row++) {
                copy.setRange(
                  row * w * 4,
                  (row + 1) * w * 4,
                  _pixels!,
                  ((sy + row) * width + sx) * 4,
                );
              }
              for (var row = 0; row < h; row++) {
                _pixels!.setRange(
                  ((y + row) * width + x) * 4,
                  ((y + row) * width + x + w) * 4,
                  copy,
                  row * w * 4,
                );
              }
            } else {
              throw const FormatException('服务器发送了未协商的 VNC 编码');
            }
          }
          if (!locked && !closed) {
            frame = Uint8List.fromList(_pixels!);
            notifyListeners();
          }
          _requestUpdate(true);
        } else if (type == 2) {
          /* Bell; no unsolicited sound. */
        } else if (type == 3) {
          await r.read(3);
          final length = await r.u32();
          if (length > 1048576) throw const FormatException('VNC 剪贴板过大');
          await r.read(
            length,
          ); // Never change the local clipboard automatically.
        } else {
          throw const FormatException('未知 VNC 服务端消息');
        }
      }
    } catch (_) {
      if (!closed) {
        connected = false;
        status = '已断开';
        error = 'VNC 连接结束或收到无效数据';
        notifyListeners();
      }
      _socket?.destroy();
    }
  }

  void key(int keysym, bool down) {
    if (!connected || closed || locked) return;
    final bytes = ByteData(8)
      ..setUint8(0, 4)
      ..setUint8(1, down ? 1 : 0)
      ..setUint32(4, keysym);
    _send(bytes.buffer.asUint8List());
  }

  void pointer(int x, int y, int buttons) {
    if (!connected || closed || locked) return;
    final bytes = ByteData(6)
      ..setUint8(0, 5)
      ..setUint8(1, buttons & 255)
      ..setUint16(2, x.clamp(0, width - 1))
      ..setUint16(4, y.clamp(0, height - 1));
    _send(bytes.buffer.asUint8List());
  }

  void setLocked(bool value) {
    _epoch++;
    locked = value;
    if (!value) _requestUpdate(false);
    notifyListeners();
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    _epoch++;
    connected = false;
    _socket?.destroy();
    await _reader?.iterator.cancel();
    await _jump?.close();
    frame = null;
    _pixels = null;
    status = '已关闭';
    notifyListeners();
  }
}
