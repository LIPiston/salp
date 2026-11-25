import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

/// One OpenSSH-agent packet over a strictly local Windows pipe. Every kernel
/// read/write is overlapped: waiting never blocks Flutter's event loop.
Future<Uint8List> windowsAgentRequest(
  String path,
  Uint8List payload,
  void Function() authorize,
) async {
  path = path.isEmpty ? r'\\.\pipe\openssh-ssh-agent' : path;
  if (!RegExp(
    r'^\\\\\.\\pipe\\[^\\/\x00-\x20:]{1,200}$',
    caseSensitive: false,
  ).hasMatch(path)) {
    throw const FormatException('Windows ssh-agent 仅允许本机 \\\\.\\pipe\\ 命名管道');
  }
  if (_active >= 4) throw StateError('ssh-agent 请求过多，请稍后重试');
  _active++;
  final clock = Stopwatch()..start();
  final name = path.toNativeUtf16();
  win.HANDLE? pipe;
  void check() {
    authorize();
    if (clock.elapsed >= const Duration(seconds: 15)) {
      throw TimeoutException('ssh-agent 请求超时');
    }
  }

  try {
    while (true) {
      check();
      final opened = win.CreateFile(
        win.PCWSTR(name),
        win.GENERIC_READ | win.GENERIC_WRITE,
        const win.FILE_SHARE_MODE(0),
        null,
        win.OPEN_EXISTING,
        win.FILE_FLAG_OVERLAPPED |
            win.SECURITY_SQOS_PRESENT |
            win.SECURITY_IMPERSONATION,
        null,
      );
      if (opened.value != win.INVALID_HANDLE_VALUE) {
        pipe = opened.value;
        break;
      }
      if (opened.error != win.ERROR_PIPE_BUSY) {
        throw StateError(
          '无法连接本机 ssh-agent（Windows ${opened.error}）；请启动 OpenSSH Authentication Agent 并加载密钥',
        );
      }
      if (clock.elapsed >= const Duration(seconds: 5)) {
        throw TimeoutException('ssh-agent 管道忙，连接超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final handle = pipe;

    Future<Uint8List> transfer(int count, {Uint8List? output}) async {
      final buffer = calloc<Uint8>(count);
      if (output != null) buffer.asTypedList(count).setAll(0, output);
      final overlapped = calloc<win.OVERLAPPED>();
      final transferred = calloc<Uint32>();
      final event = win.CreateEvent(null, true, false, null).value;
      var pending = false;
      try {
        if (event.address == 0) throw StateError('ssh-agent 无法创建管道事件');
        overlapped.ref.hEvent = event;
        check();
        final started = output == null
            ? win.ReadFile(handle, buffer, count, transferred, overlapped)
            : win.WriteFile(handle, buffer, count, transferred, overlapped);
        if (!started.value && started.error != win.ERROR_IO_PENDING) {
          throw StateError('ssh-agent 管道读写失败（Windows ${started.error}）');
        }
        pending = !started.value;
        while (pending) {
          check();
          final result = win.GetOverlappedResult(
            handle,
            overlapped,
            transferred,
            false,
          );
          if (result.value) {
            pending = false;
          } else if (result.error != win.ERROR_IO_INCOMPLETE) {
            pending = false;
            throw StateError('ssh-agent 响应不完整（Windows ${result.error}）');
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        check();
        final length = transferred.value;
        if (length == 0 || length > count) throw StateError('ssh-agent 响应不完整');
        // A single WriteFile may be partial; the caller sends its remainder.
        return output == null
            ? Uint8List.fromList(buffer.asTypedList(length))
            : (ByteData(4)..setUint32(0, length)).buffer.asUint8List();
      } finally {
        if (pending) {
          win.CancelIoEx(handle, overlapped);
          // CancelIoEx only requests cancellation. The kernel still owns these
          // allocations until completion, including when cancellation races IO.
          while (true) {
            final settled = win.GetOverlappedResult(
              handle,
              overlapped,
              transferred,
              false,
            );
            if (settled.value || settled.error != win.ERROR_IO_INCOMPLETE) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }
        if (event.address != 0) win.CloseHandle(event);
        calloc.free(transferred);
        calloc.free(overlapped);
        calloc.free(buffer);
      }
    }

    final frame = Uint8List.fromList([
      ...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
      ...payload,
    ]);
    var sent = 0;
    while (sent < frame.length) {
      final count = await transfer(
        frame.length - sent,
        output: Uint8List.sublistView(frame, sent),
      );
      sent += ByteData.sublistView(count).getUint32(0);
    }
    Future<Uint8List> read(int count) async {
      final result = BytesBuilder(copy: false);
      while (result.length < count) {
        result.add(await transfer(count - result.length));
      }
      return result.takeBytes();
    }

    final length = ByteData.sublistView(await read(4)).getUint32(0);
    if (length < 1 || length > 256 * 1024) {
      throw StateError('ssh-agent 响应长度无效');
    }
    final reply = await read(length);
    check();
    return reply;
  } finally {
    if (pipe != null) win.CloseHandle(pipe);
    calloc.free(name);
    _active--;
  }
}

int _active = 0;
