import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/telnet_codec.dart';

void main() {
  test('telnet strips split negotiation and preserves escaped IAC', () {
    final replies = <List<int>>[];
    final codec = TelnetCodec(replies.add);
    expect(codec.decode([65, 255, 251]), [65]);
    expect(codec.decode([1, 66, 255, 255, 67]), [66, 255, 67]);
    expect(replies, [
      [255, 253, 1],
    ]);
  });
  test('telnet refuses unknown options and strips split subnegotiation', () {
    final replies = <List<int>>[];
    final codec = TelnetCodec(replies.add);
    expect(codec.decode([255, 253, 99, 255, 250, 42, 0]), isEmpty);
    expect(codec.decode([1, 255, 240, 68]), [68]);
    expect(replies, [
      [255, 252, 99],
    ]);
  });
}
