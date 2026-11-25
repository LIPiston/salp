import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

class SerialException implements Exception {
  const SerialException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef _ConfigNative = Int32 Function(Pointer<Void>, Int32);
typedef _Config = int Function(Pointer<Void>, int);
typedef _IoNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _Io = int Function(Pointer<Void>, Pointer<Uint8>, int);

class _SerialApi {
  _SerialApi()
    : lib = DynamicLibrary.open(
        Platform.isWindows ? 'libserialport.dll' : 'libserialport.so.0',
      );
  final DynamicLibrary lib;
  late final getPort = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>),
        int Function(Pointer<Utf8>, Pointer<Pointer<Void>>)
      >('sp_get_port_by_name');
  late final list = lib
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Pointer<Void>>>),
        int Function(Pointer<Pointer<Pointer<Void>>>)
      >('sp_list_ports');
  late final freeList = lib
      .lookupFunction<
        Void Function(Pointer<Pointer<Void>>),
        void Function(Pointer<Pointer<Void>>)
      >('sp_free_port_list');
  late final name = lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>),
        Pointer<Utf8> Function(Pointer<Void>)
      >('sp_get_port_name');
  late final open = lib.lookupFunction<_ConfigNative, _Config>('sp_open');
  late final close = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('sp_close');
  late final free = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('sp_free_port');
  late final read = lib.lookupFunction<_IoNative, _Io>('sp_nonblocking_read');
  late final write = lib.lookupFunction<_IoNative, _Io>('sp_nonblocking_write');
  _Config config(String name) =>
      lib.lookupFunction<_ConfigNative, _Config>(name);
}

/// Nonblocking libserialport calls; input and output budgets prevent UI stalls.
class SerialConnection {
  SerialConnection._(this._api, this._port) {
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _read());
  }
  final _SerialApi _api;
  final Pointer<Void> _port;
  final _buffer = calloc<Uint8>(16384);
  final _output = StreamController<Uint8List>();
  late final Timer _timer;
  bool _closed = false;
  Stream<Uint8List> get output => _output.stream;

  static _SerialApi _load() {
    if (Platform.isAndroid) throw const SerialException('Android 不提供本地串口');
    try {
      return _SerialApi();
    } catch (_) {
      throw const SerialException('无法加载 libserialport；请安装系统串口库');
    }
  }

  static List<String> listPorts() {
    final api = _load();
    final out = calloc<Pointer<Pointer<Void>>>();
    try {
      _check(api.list(out));
      final result = <String>[];
      if (out.value != nullptr) {
        for (var i = 0; i < 256 && out.value[i] != nullptr; i++) {
          final name = api.name(out.value[i]);
          if (name != nullptr) result.add(name.toDartString());
        }
      }
      return result;
    } finally {
      if (out.value != nullptr) api.freeList(out.value);
      calloc.free(out);
    }
  }

  static SerialConnection open(
    String path, {
    int baud = 115200,
    int bits = 8,
    int stopBits = 1,
    int parity = 0,
    int flowControl = 0,
  }) {
    if (path.isEmpty ||
        path.contains('\x00') ||
        baud < 50 ||
        baud > 4000000 ||
        bits < 5 ||
        bits > 8 ||
        stopBits < 1 ||
        stopBits > 2 ||
        parity < 0 ||
        parity > 4 ||
        flowControl < 0 ||
        flowControl > 2) {
      throw const FormatException('串口参数无效');
    }
    final api = _load();
    final out = calloc<Pointer<Void>>();
    final name = path.toNativeUtf8();
    var opened = false;
    try {
      _check(api.getPort(name, out));
      _check(api.open(out.value, 3));
      opened = true;
      for (final entry in {
        'sp_set_baudrate': baud,
        'sp_set_bits': bits,
        'sp_set_stopbits': stopBits,
        'sp_set_parity': parity,
        'sp_set_flowcontrol': flowControl,
      }.entries) {
        _check(api.config(entry.key)(out.value, entry.value));
      }
      return SerialConnection._(api, out.value);
    } catch (_) {
      if (out.value != nullptr) {
        if (opened) api.close(out.value);
        api.free(out.value);
      }
      rethrow;
    } finally {
      calloc.free(name);
      calloc.free(out);
    }
  }

  static void _check(int result) {
    if (result < 0) throw SerialException('串口操作失败（$result），请检查设备、占用情况和用户权限');
  }

  void _read() {
    if (_closed || _output.isPaused) return;
    try {
      // At most 64 KiB per timer tick.
      for (var i = 0; i < 4; i++) {
        final count = _api.read(_port, _buffer, 16384);
        _check(count);
        if (count == 0) break;
        _output.add(Uint8List.fromList(_buffer.asTypedList(count)));
      }
    } catch (e, stack) {
      _output.addError(e, stack);
      close();
    }
  }

  Future<void> write(Uint8List bytes, {void Function()? authorize}) async {
    if (_closed) throw const SerialException('串口已关闭');
    if (bytes.length > 65536) throw const SerialException('串口输入超过 64 KiB 上限');
    final buffer = calloc<Uint8>(bytes.length);
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        authorize?.call();
        if (_closed) throw const SerialException('串口已关闭，输入结果未知');
        final count = _api.write(_port, buffer + offset, bytes.length - offset);
        _check(count);
        offset += count;
        if (DateTime.now().isAfter(deadline)) {
          throw const SerialException('串口写入超时，部分数据可能已发送');
        }
        if (offset < bytes.length) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
    } finally {
      calloc.free(buffer);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    _api.close(_port);
    _api.free(_port);
    calloc.free(_buffer);
    unawaited(_output.close());
  }
}
