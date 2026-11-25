import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'connection.dart';
import 'host.dart';
import 'repository.dart';
import 'tunnels.dart';
import 'vnc.dart';

typedef _StartNative = Pointer<Void> Function(
  Pointer<Utf8>,
  Int32,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
);
typedef _Start = Pointer<Void> Function(
  Pointer<Utf8>,
  int,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
);

class _RdpApi {
  _RdpApi()
    : lib = DynamicLibrary.open(
        Platform.isWindows ? 'salp_rdp.dll' : 'libsalp_rdp.so',
      );
  final DynamicLibrary lib;
  late final start = lib.lookupFunction<_StartNative, _Start>('salp_rdp_start');
  late final state = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('salp_rdp_state');
  late final error = lib
      .lookupFunction<
        Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('salp_rdp_error');
  late final frame = lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint8>,
          Int32,
          Pointer<Int32>,
          Pointer<Int32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint8>,
          int,
          Pointer<Int32>,
          Pointer<Int32>,
        )
      >('salp_rdp_frame');
  late final certificate = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32),
        int Function(Pointer<Void>, Pointer<Utf8>, int)
      >('salp_rdp_certificate');
  late final trust = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('salp_rdp_trust');
  late final input = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int32),
        int Function(Pointer<Void>, int, int, int, int)
      >('salp_rdp_input');
  late final lock = lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('salp_rdp_lock');
  late final stop = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('salp_rdp_stop');
  late final free = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('salp_rdp_free');
}

typedef RdpCertificatePrompt = Future<bool> Function(String details);

/// Shares the framebuffer/input view contract with VNC, never its protocol.
class RdpSession extends VncSession {
  RdpSession(super.host, {required this.verifyCertificate});
  final RdpCertificatePrompt verifyCertificate;
  _RdpApi? _api;
  Pointer<Void> _handle = nullptr;
  Pointer<Uint8> _buffer = nullptr;
  int _capacity = 0, _generation = 0, _buttons = 0;
  final _width = calloc<Int32>(), _height = calloc<Int32>();
  Timer? _poller;
  SshConnection? _jump;
  Tunnel? _tunnel;
  bool _prompting = false;
  final _modifiers = <int>{};
  final _scanPressed = <int, int>{};
  @override
  Future<void> open(
    Repository repo,
    VerifyHost verify,
    PromptAuth prompt,
  ) async {
    final authority = repo.epoch, generation = _generation;
    void check() {
      repo.checkAuthority(authority);
      if (closed || locked || generation != _generation) {
        throw StateError('RDP 连接上下文失效');
      }
    }

    try {
      check();
      host.validate();
      _api = _RdpApi();
      var address = host.address, port = host.port;
      if (host.jumpIds.isNotEmpty) {
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
        _tunnel = await Tunnel.local(_jump!.client, 0, host.address, host.port);
        check();
        address = '127.0.0.1';
        port = int.parse(
          _tunnel!.description.split(' → ').first.split(':').last,
        );
      }
      final credentials = repo.credentials[host.id];
      var user = host.username, domain = '';
      if (user.contains(r'\')) {
        final index = user.indexOf(r'\');
        domain = user.substring(0, index);
        user = user.substring(index + 1);
      }
      final config = Directory('${repo.directory.path}/rdp');
      await config.create(recursive: true);
      check();
      final strings = [
        address,
        user,
        credentials?.password ?? '',
        domain,
        host.address,
        config.path,
      ].map((s) => s.toNativeUtf8()).toList();
      try {
        _handle = _api!.start(
          strings[0],
          port,
          strings[1],
          strings[2],
          strings[3],
          strings[4],
          strings[5],
          1280,
          720,
        );
      } finally {
        final secret = strings[2].cast<Uint8>();
        secret
            .asTypedList(strings[2].length)
            .fillRange(0, strings[2].length, 0);
        for (final s in strings) {
          calloc.free(s);
        }
      }
      if (_handle == nullptr) throw StateError('FreeRDP 初始化失败');
      _poller = Timer.periodic(
        const Duration(milliseconds: 33),
        (_) => _poll(repo),
      );
    } catch (e) {
      error = e is TrustSaved
          ? e.toString()
          : 'RDP 无法启动：请检查本机 FreeRDP 库、跳板和连接设置';
      status = '连接失败';
      await _tunnel?.close();
      await _jump?.close();
    }
    notifyListeners();
  }

  void _poll(Repository repo) {
    if (closed || _handle == nullptr) return;
    final state = _api!.state(_handle);
    if (state == 2 && !_prompting && !locked) {
      final buffer = calloc<Uint8>(16385);
      final length = _api!.certificate(_handle, buffer.cast(), 16385);
      final details = buffer.cast<Utf8>().toDartString(length: length);
      calloc.free(buffer);
      _prompting = true;
      final authority = repo.epoch, generation = _generation;
      verifyCertificate(details)
          .then((accepted) {
            if (_handle != nullptr) {
              _api!.trust(
                _handle,
                accepted &&
                        !closed &&
                        !locked &&
                        !repo.locked &&
                        repo.epoch == authority &&
                        generation == _generation
                    ? 1
                    : 0,
              );
            }
          })
          .catchError((Object _) {
            if (_handle != nullptr) _api!.trust(_handle, 0);
          })
          .whenComplete(() => _prompting = false);
    }
    if (state == 1) {
      connected = true;
      status = 'RDP · TLS';
      if (!locked) {
        var size = _api!.frame(_handle, _buffer, _capacity, _width, _height);
        if (size < 0) {
          final required = -size;
          if (required > 64 * 1024 * 1024) {
            unawaited(close());
            return;
          }
          if (_buffer != nullptr) calloc.free(_buffer);
          _buffer = calloc<Uint8>(required);
          _capacity = required;
          size = _api!.frame(_handle, _buffer, _capacity, _width, _height);
        }
        if (size > 0) {
          width = _width.value;
          height = _height.value;
          frame = Uint8List.fromList(_buffer.asTypedList(size));
        }
      }
    } else if (state == -1 || state == 3) {
      connected = false;
      status = state == -1 ? '连接失败' : '已断开';
      if (state == -1) {
        error =
            'RDP 连接失败（FreeRDP ${_api!.error(_handle).toRadixString(16)}），请检查认证、证书与服务器设置';
      }
      _poller?.cancel();
    }
    notifyListeners();
  }

  @override
  void key(int keysym, bool down) {
    if (closed || locked || !connected || _handle == nullptr) return;
    const scan = <int, int>{
      0xff1b: 0x01,
      0xff08: 0x0e,
      0xff09: 0x0f,
      0xff0d: 0x1c,
      0xffe1: 0x2a,
      0xffe2: 0x36,
      0xffe3: 0x1d,
      0xffe4: 0x11d,
      0xffe9: 0x38,
      0xffea: 0x138,
      0xffeb: 0x15b,
      0xffec: 0x15c,
      0xff51: 0x14b,
      0xff52: 0x148,
      0xff53: 0x14d,
      0xff54: 0x150,
      0xff50: 0x147,
      0xff57: 0x14f,
      0xff55: 0x149,
      0xff56: 0x151,
      0xffff: 0x153,
      0xff63: 0x152,
    };
    const modifierKeys = {0xffe3, 0xffe4, 0xffe9, 0xffea, 0xffeb, 0xffec};
    if (modifierKeys.contains(keysym)) {
      if (down) {
        _modifiers.add(keysym);
      } else {
        _modifiers.remove(keysym);
      }
    }
    var code = scan[keysym];
    // RDP Unicode events insert characters; they do not reliably implement
    // Ctrl/Alt/Meta shortcuts. Send the physical US-layout key for those chords.
    if (_modifiers.isNotEmpty && keysym < 128) {
      const letters = <int>[
        0x1e,
        0x30,
        0x2e,
        0x20,
        0x12,
        0x21,
        0x22,
        0x23,
        0x17,
        0x24,
        0x25,
        0x26,
        0x32,
        0x31,
        0x18,
        0x19,
        0x10,
        0x13,
        0x1f,
        0x14,
        0x16,
        0x2f,
        0x11,
        0x2d,
        0x15,
        0x2c,
      ];
      final lower = keysym >= 65 && keysym <= 90 ? keysym + 32 : keysym;
      if (lower >= 97 && lower <= 122) {
        code = letters[lower - 97];
      } else {
        code = const <int, int>{
          48: 0x0b,
          49: 0x02,
          50: 0x03,
          51: 0x04,
          52: 0x05,
          53: 0x06,
          54: 0x07,
          55: 0x08,
          56: 0x09,
          57: 0x0a,
          32: 0x39,
          45: 0x0c,
          61: 0x0d,
          91: 0x1a,
          93: 0x1b,
          92: 0x2b,
          59: 0x27,
          39: 0x28,
          96: 0x29,
          44: 0x33,
          46: 0x34,
          47: 0x35,
        }[keysym];
      }
    }
    if (!down) code = _scanPressed.remove(keysym) ?? code;
    if (keysym >= 0xffbe && keysym <= 0xffc9) {
      code = [
        0x3b,
        0x3c,
        0x3d,
        0x3e,
        0x3f,
        0x40,
        0x41,
        0x42,
        0x43,
        0x44,
        0x57,
        0x58,
      ][keysym - 0xffbe];
    }
    if (code != null) {
      if (down) _scanPressed[keysym] = code;
      _api!.input(
        _handle,
        1,
        (down ? 0 : 0x8000) | (code & 0x100),
        code & 255,
        0,
      );
    } else {
      final unicode = keysym & 0x00ffffff;
      if (unicode <= 0x10ffff && !(unicode >= 0xd800 && unicode <= 0xdfff)) {
        for (final unit in String.fromCharCode(unicode).codeUnits) {
          _api!.input(_handle, 2, down ? 0 : 0x8000, unit, 0);
        }
      }
    }
  }

  @override
  void pointer(int x, int y, int buttons) {
    if (closed || locked || !connected || _handle == nullptr) return;
    x = x.clamp(0, width > 0 ? width - 1 : 4095);
    y = y.clamp(0, height > 0 ? height - 1 : 4095);
    _api!.input(_handle, 0, 0x0800, x, y);
    for (final (mask, flag) in [(1, 0x1000), (2, 0x4000), (4, 0x2000)]) {
      if ((buttons & mask) != (_buttons & mask)) {
        _api!.input(
          _handle,
          0,
          flag | (buttons & mask != 0 ? 0x8000 : 0),
          x,
          y,
        );
      }
    }
    if (buttons & 8 != 0) _api!.input(_handle, 0, 0x0200 | 120, x, y);
    if (buttons & 16 != 0) {
      _api!.input(_handle, 0, 0x0200 | 0x0100 | 0x88, x, y);
    }
    _buttons = buttons & 7;
  }

  @override
  void setLocked(bool value) {
    _generation++;
    _modifiers.clear();
    _scanPressed.clear();
    locked = value;
    if (_handle != nullptr) _api!.lock(_handle, value ? 1 : 0);
    notifyListeners();
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    connected = false;
    _generation++;
    _poller?.cancel();
    final handle = _handle;
    _handle = nullptr;
    if (handle != nullptr) {
      _api!.stop(handle);
      // Join only after the native thread reports exit, never block Flutter.
      final api = _api!;
      Future<void> cleanup() async {
        while (api.state(handle) != 3 && api.state(handle) != -1) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        api.free(handle);
      }

      unawaited(cleanup());
    }
    if (_buffer != nullptr) {
      calloc.free(_buffer);
      _buffer = nullptr;
    }
    calloc.free(_width);
    calloc.free(_height);
    frame = null;
    await _tunnel?.close();
    await _jump?.close();
    status = '已关闭';
    notifyListeners();
  }
}
