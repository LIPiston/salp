import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'vault_cipher.dart';

class MasterPassword {
  static Future<Uint8List> deriveKey(String password, Uint8List salt) async =>
      base64.decode(
        await compute(_derive, {
          'password': password,
          'salt': base64.encode(salt),
        }),
      );

  static Future<Map<String, String>> create(String password) async {
    if (password.length < 8) throw const FormatException('主密码至少需要 8 个字符');
    final salt = VaultCipher.randomBytes(16);
    final digest = await compute(_derive, {
      'password': password,
      'salt': base64.encode(salt),
    });
    return {
      'salt': base64.encode(salt),
      'digest': digest,
      'algorithm': 'argon2id-v1',
    };
  }

  static Future<bool> verify(
    String password,
    Map<String, String> record,
  ) async {
    if (record['algorithm'] != 'argon2id-v1') return false;
    final actual = base64.decode(
      await compute(_derive, {'password': password, 'salt': record['salt']!}),
    );
    final expected = base64.decode(record['digest']!);
    var diff = actual.length ^ expected.length;
    for (var i = 0; i < actual.length && i < expected.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }
}

String _derive(Map<String, String> input) {
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        base64.decode(input['salt']!),
        desiredKeyLength: 32,
        memory: 19456,
        iterations: 2,
        lanes: 1,
      ),
    );
  return base64.encode(
    generator.process(Uint8List.fromList(utf8.encode(input['password']!))),
  );
}
