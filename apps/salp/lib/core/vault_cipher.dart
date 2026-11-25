import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class VaultCipher {
  static final _header = Uint8List.fromList([83, 65, 76, 80, 1]);
  static Uint8List randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  Uint8List seal(Uint8List clear, Uint8List key) {
    if (key.length != 32) throw ArgumentError('Invalid encryption key');
    final nonce = randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, _header));
    return Uint8List.fromList([..._header, ...nonce, ...cipher.process(clear)]);
  }

  Uint8List open(Uint8List envelope, Uint8List key) {
    if (key.length != 32 || envelope.length < 33) {
      throw const FormatException('Invalid vault');
    }
    for (var i = 0; i < _header.length; i++) {
      if (envelope[i] != _header[i]) {
        throw const FormatException('Invalid vault');
      }
    }
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          128,
          Uint8List.sublistView(envelope, 5, 17),
          _header,
        ),
      );
    return cipher.process(Uint8List.sublistView(envelope, 17));
  }
}
