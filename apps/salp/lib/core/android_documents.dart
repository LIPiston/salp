import 'package:flutter/services.dart';

/// Android SAF streams. A content URI is never treated as a filesystem path.
class AndroidDocuments {
  static const channel = MethodChannel('dev.salp/documents');
  static Future<Map<String, int>> recoveryStatus() async =>
      await channel.invokeMapMethod<String, int>('recovery') ?? {};
  static Future<String?> chooseDirectory() =>
      channel.invokeMethod<String>('chooseDirectory');
  static Future<String> create(
    String directory,
    String name, {
    bool keepBoth = false,
  }) async {
    final id = await channel.invokeMethod<String>('create', {
      'directory': directory,
      'name': name,
      'keepBoth': keepBoth,
    });
    if (id == null) throw StateError('无法创建目标文件');
    return id;
  }

  static Future<void> write(String id, Uint8List bytes) async {
    for (var offset = 0; offset < bytes.length; offset += 65536) {
      await channel.invokeMethod<void>('write', {
        'id': id,
        'bytes': Uint8List.sublistView(
          bytes,
          offset,
          (offset + 65536).clamp(0, bytes.length),
        ),
      });
    }
  }

  static Future<void> finish(String id) =>
      channel.invokeMethod<void>('finish', {'id': id});
  static Future<void> abort(String id) =>
      channel.invokeMethod<void>('abort', {'id': id});
}
