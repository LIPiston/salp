import 'dart:typed_data';

import 'package:dartssh2/src/sftp/sftp_name.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SFTP filename bytes survive decoding and re-encoding', () {
    final writer = SSHMessageWriter();
    writer.writeString(Uint8List.fromList([0x80, 0x81, 0xff]));
    writer.writeString(Uint8List.fromList([0x82]));
    writer.writeUint32(0);
    final original = writer.takeBytes();
    final name = SftpName.readFrom(SSHMessageReader(original));
    final encoded = SSHMessageWriter();
    name.writeTo(encoded);
    expect(encoded.takeBytes(), original);
  });
}
