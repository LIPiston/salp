import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'vault_cipher.dart';

/// Encrypted, length-delimited records. Crash truncation is reported on read.
/// Nothing is logged until the human explicitly enables it for this session.
class SessionLog {
  SessionLog._(this.file, this._output, this._key, this.maxBytes);
  final File file;
  final RandomAccessFile _output;
  final Uint8List _key;
  final int maxBytes;
  bool limited = false, _closed = false;
  int _bytes = 0;
  static Future<void> prune(Directory directory) async {
    if (!await directory.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File && entry.path.endsWith('.salp-log')) {
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          await entry.delete();
        }
      }
    }
  }

  static Future<SessionLog> start(
    Directory directory,
    Uint8List key, {
    int maxBytes = 16 * 1024 * 1024,
  }) async {
    await directory.create(recursive: true);
    await prune(directory);
    final id = base64Url.encode(VaultCipher.randomBytes(12));
    final file = File(
      '${directory.path}/${DateTime.now().millisecondsSinceEpoch}-$id.salp-log',
    );
    await file.create(exclusive: true);
    return SessionLog._(
      file,
      await file.open(mode: FileMode.writeOnly),
      key,
      maxBytes,
    );
  }

  bool append(String text, {bool flush = false}) {
    if (_closed || limited) return false;
    // Reject huge chunks before encoding/copying; never queue unbounded IO.
    if (text.length > maxBytes || _bytes + text.length > maxBytes) {
      limited = true;
      return false;
    }
    final bytes = VaultCipher().seal(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'at': DateTime.now().toUtc().toIso8601String(),
            'text': text,
          }),
        ),
      ),
      _key,
    );
    if (_bytes + bytes.length + 4 > maxBytes) {
      limited = true;
      return false;
    }
    final size = ByteData(4)..setUint32(0, bytes.length);
    try {
      _output.writeFromSync(size.buffer.asUint8List());
      _output.writeFromSync(bytes);
      if (flush) _output.flushSync();
      _bytes += bytes.length + 4;
    } catch (_) {
      // A short write may have left a partial record. Never append after it.
      limited = true;
      rethrow;
    }
    return true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _output.flush();
    } finally {
      await _output.close();
    }
  }

  static Future<List<Map<String, dynamic>>> read(
    File file,
    Uint8List key,
  ) async {
    if (await file.length() > 16 * 1024 * 1024) {
      throw const FormatException('日志过大');
    }
    final bytes = await file.readAsBytes();
    final rows = <Map<String, dynamic>>[];
    var offset = 0;
    while (offset < bytes.length) {
      if (bytes.length - offset < 4) throw const FormatException('日志末尾不完整');
      final length = ByteData.sublistView(
        bytes,
        offset,
        offset + 4,
      ).getUint32(0);
      offset += 4;
      if (length < 33 || length > bytes.length - offset) {
        throw const FormatException('日志记录不完整');
      }
      final clear = VaultCipher().open(
        Uint8List.sublistView(bytes, offset, offset + length),
        key,
      );
      rows.add(
        Map<String, dynamic>.from(jsonDecode(utf8.decode(clear)) as Map),
      );
      offset += length;
    }
    return rows;
  }
}
