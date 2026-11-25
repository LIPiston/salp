import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/vault_cipher.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final clear = Uint8List.fromList(utf8.encode('private-key-and-password-秘密'));
  test('vault authenticates contents and hides plaintext', () {
    final cipher = VaultCipher();
    final sealed = cipher.seal(clear, key);
    expect(sealed, isNot(equals(clear)));
    expect(cipher.open(sealed, key), clear);
    sealed[sealed.length - 1] ^= 1;
    expect(() => cipher.open(sealed, key), throwsA(anything));
  });
  test('vault rejects wrong keys and uses unique nonces', () {
    final cipher = VaultCipher();
    final sealed = cipher.seal(clear, key);
    expect(sealed, isNot(equals(cipher.seal(clear, key))));
    expect(() => cipher.open(sealed, Uint8List(32)), throwsA(anything));
    expect(() => cipher.open(Uint8List(4), key), throwsA(anything));
  });
}
