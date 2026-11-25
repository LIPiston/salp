import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _LinkNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _Link = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _MoveNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _Move = int Function(Pointer<Utf16>, Pointer<Utf16>);

/// Atomically publish a sibling staging file without overwriting any target.
/// POSIX hard-link creation and Windows MoveFile both fail if target exists.
/// Unsupported filesystems fail explicitly, never fall back to replacing rename.
Future<void> commitNoReplace(File staging, File target) async {
  if (Platform.isWindows) {
    final move = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_MoveNative, _Move>('MoveFileW');
    final from = staging.path.toNativeUtf16(), to = target.path.toNativeUtf16();
    try {
      if (move(from, to) == 0) {
        throw FileSystemException('无法提交下载：目标已存在或文件系统拒绝操作', target.path);
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
    return;
  }
  final link = DynamicLibrary.process().lookupFunction<_LinkNative, _Link>(
    'link',
  );
  final from = staging.path.toNativeUtf8(), to = target.path.toNativeUtf8();
  try {
    if (link(from, to) != 0) {
      throw FileSystemException('无法提交下载：目标已存在或文件系统不支持硬链接', target.path);
    }
  } finally {
    calloc.free(from);
    calloc.free(to);
  }
  // Once linked, the completed destination is authoritative. Retaining an
  // undeletable staging name is preferable to retrying an already committed job.
  try {
    await staging.delete();
  } on FileSystemException {
    /* kept for cleanup */
  }
}
