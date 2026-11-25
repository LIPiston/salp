import 'dart:typed_data';

/// Incremental Telnet command decoder. Only ECHO and suppress-go-ahead accepted.
class TelnetCodec {
  TelnetCodec(this.reply);
  final void Function(Uint8List) reply;
  int _state = 0, _command = 0;
  final _enabled = <int>{};
  Uint8List decode(List<int> bytes) {
    final output = <int>[];
    for (final byte in bytes) {
      switch (_state) {
        case 0:
          if (byte == 255) {
            _state = 1;
          } else {
            output.add(byte);
          }
        case 1:
          if (byte == 255) {
            output.add(255);
            _state = 0;
          } else if (byte >= 251 && byte <= 254) {
            _command = byte;
            _state = 2;
          } else if (byte == 250) {
            _state = 3;
          } else {
            _state = 0;
          }
        case 2:
          if (_command == 251) {
            if (byte == 1 || byte == 3) {
              if (_enabled.add(byte)) {
                reply(Uint8List.fromList([255, 253, byte]));
              }
            } else {
              reply(Uint8List.fromList([255, 254, byte]));
            }
          } else if (_command == 253) {
            reply(Uint8List.fromList([255, 252, byte]));
          } else if (_command == 252) {
            _enabled.remove(byte);
          }
          _state = 0;
        case 3:
          if (byte == 255) _state = 4;
        case 4:
          _state = byte == 240 ? 0 : 3;
      }
    }
    return Uint8List.fromList(output);
  }
}
