import 'dart:typed_data';

/// Bound allocation before appending a file-picker chunk and recheck the modal's
/// authority across every asynchronous boundary, including end of stream.
Future<Uint8List> readBounded(
  Stream<List<int>> stream, {
  required int maxBytes,
  required void Function() authorize,
}) async {
  authorize();
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    authorize();
    if (chunk.length > maxBytes - bytes.length) {
      throw const FormatException('文件超过大小上限');
    }
    bytes.add(chunk);
  }
  authorize();
  return bytes.takeBytes();
}
