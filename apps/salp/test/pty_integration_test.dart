import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_pty/flutter_pty.dart';

void main() {
  test(
    'real PTY executes UTF-8 input and applies resize',
    () async {
      final pty = Pty.start(
        '/bin/sh',
        arguments: ['-f'],
        environment: {'ENV': '/dev/null', 'LANG': 'C.UTF-8'},
        columns: 80,
        rows: 24,
      );
      final done = Completer<void>();
      final text = StringBuffer();
      final sub = pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((s) {
            text.write(s);
            if (text.toString().contains('SALP_PTY_EXECUTED') &&
                !done.isCompleted) {
              done.complete();
            }
          });
      try {
        pty.resize(37, 113);
        pty.write(
          Uint8List.fromList(
            utf8.encode(
              "stty size; printf '%s%s\\n' 'SALP_PTY_' 'EXECUTED'; printf '%s\\n' '中文'; exit\n",
            ),
          ),
        );
        await done.future.timeout(const Duration(seconds: 10));
        expect(await pty.exitCode.timeout(const Duration(seconds: 5)), 0);
        expect(text.toString(), contains('37 113'));
        expect(text.toString(), contains('中文'));
      } finally {
        pty.kill();
        await sub.cancel();
      }
    },
    skip: Platform.environment['SALP_PTY_FIXTURE'] == null
        ? 'Requires built Linux libflutter_pty.so'
        : false,
  );
}
