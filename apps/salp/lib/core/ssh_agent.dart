import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// OpenSSH agent protocol, one bounded request per local socket connection.
/// Agent forwarding is intentionally separate; this only signs local auth.
class DesktopSshAgent {
  DesktopSshAgent(this.path, this.authorize);
  final String path;
  final void Function() authorize;
  static const _limit = 256 * 1024;

  Future<Uint8List> _request(Uint8List payload) async {
    authorize();
    if (Platform.isAndroid) throw UnsupportedError('Android 不提供桌面 ssh-agent');
    if (Platform.isWindows) {
      throw UnsupportedError('Windows ssh-agent 命名管道尚未接入');
    }
    if (path.isEmpty) throw StateError('未找到 SSH_AUTH_SOCK，请启动 ssh-agent 并加载密钥');
    final socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
      timeout: const Duration(seconds: 5),
    );
    final reader = StreamIterator<Uint8List>(socket);
    var buffered = Uint8List(0);
    Future<Uint8List> read(int count) async {
      while (buffered.length < count) {
        if (!await reader.moveNext().timeout(const Duration(seconds: 15))) {
          throw StateError('ssh-agent 响应不完整');
        }
        if (buffered.length + reader.current.length > _limit + 4) {
          throw StateError('ssh-agent 响应过大');
        }
        buffered = Uint8List.fromList([...buffered, ...reader.current]);
      }
      final result = Uint8List.fromList(buffered.sublist(0, count));
      buffered = Uint8List.fromList(buffered.sublist(count));
      return result;
    }

    try {
      authorize();
      socket.add(_uint32(payload.length));
      socket.add(payload);
      await socket.flush();
      final length = ByteData.sublistView(await read(4)).getUint32(0);
      if (length < 1 || length > _limit) throw StateError('ssh-agent 响应长度无效');
      final reply = await read(length);
      authorize();
      return reply;
    } finally {
      socket.destroy();
      await reader.cancel();
    }
  }

  Future<List<SSHIdentity>> identities() async {
    final reader = _AgentReader(await _request(Uint8List.fromList([11])));
    if (reader.byte() != 12) throw StateError('ssh-agent 拒绝列出密钥');
    final count = reader.uint32();
    if (count > 128) throw StateError('ssh-agent 密钥过多');
    final result = <SSHIdentity>[];
    for (var i = 0; i < count; i++) {
      final key = reader.string();
      reader.string(); // Comments are not needed for authentication or logged.
      final type = SSHHostKey.getType(key);
      final algorithm = type == 'ssh-rsa' ? 'rsa-sha2-512' : type;
      if (![
        'ssh-ed25519',
        'rsa-sha2-512',
        'ecdsa-sha2-nistp256',
        'ecdsa-sha2-nistp384',
        'ecdsa-sha2-nistp521',
      ].contains(algorithm)) {
        continue;
      }
      result.add(
        SSHIdentity.custom(
          type: algorithm,
          publicKey: SSHRawHostKey(key),
          shouldProbe: true,
          signer: (data) async {
            authorize();
            final answer = _AgentReader(
              await _request(
                Uint8List.fromList([
                  13,
                  ..._string(key),
                  ..._string(data),
                  ..._uint32(type == 'ssh-rsa' ? 4 : 0),
                ]),
              ),
            );
            if (answer.byte() != 14) throw StateError('ssh-agent 拒绝签名');
            final signature = answer.string();
            if (SSHSignature.getType(signature) != algorithm) {
              throw StateError('ssh-agent 签名算法不匹配');
            }
            return SSHRawSignature(signature);
          },
        ),
      );
    }
    if (result.isEmpty) throw StateError('ssh-agent 未加载支持的密钥');
    return result;
  }
}

Uint8List _uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> _string(Uint8List value) => [..._uint32(value.length), ...value];

class _AgentReader {
  _AgentReader(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  int byte() {
    if (offset >= bytes.length) throw const FormatException('agent 数据截断');
    return bytes[offset++];
  }

  int uint32() {
    if (bytes.length - offset < 4) throw const FormatException('agent 数据截断');
    final value = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    offset += 4;
    return value;
  }

  Uint8List string() {
    final length = uint32();
    if (length > bytes.length - offset) {
      throw const FormatException('agent 字段截断');
    }
    final value = Uint8List.fromList(bytes.sublist(offset, offset + length));
    offset += length;
    return value;
  }
}
