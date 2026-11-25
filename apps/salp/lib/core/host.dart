import 'vault_cipher.dart';

import 'dart:convert';

enum Protocol { ssh, telnet, mosh, vnc, rdp }

class Host {
  Host({
    required this.id,
    required this.name,
    required this.address,
    this.port = 22,
    this.username = 'root',
    this.group = '',
    this.protocol = Protocol.ssh,
    this.jumpIds = const [],
  });
  final String id, name, address, username, group;
  final int port;
  final Protocol protocol;
  final List<String> jumpIds;
  String get endpoint => '[$address]:$port';
  String get label => name.isEmpty ? address : name;
  static String newId() => base64Url.encode(VaultCipher.randomBytes(12));
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'port': port,
    'username': username,
    'group': group,
    'protocol': protocol.name,
    'jumps': jumpIds,
  };
  factory Host.fromJson(Map<String, dynamic> j) => Host(
    id: j['id'] as String,
    name: j['name'] as String,
    address: j['address'] as String,
    port: j['port'] as int,
    username: j['username'] as String,
    group: j['group'] as String? ?? '',
    protocol: Protocol.values.byName(j['protocol'] as String? ?? 'ssh'),
    jumpIds: List<String>.from(j['jumps'] as List? ?? []),
  );
  void validate() {
    if (address.trim().isEmpty ||
        address.contains('\x00') ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('请输入有效的主机地址与端口');
    }
    if ((protocol == Protocol.ssh || protocol == Protocol.mosh) &&
        username.trim().isEmpty) {
      throw const FormatException('用户名不能为空');
    }
    if (jumpIds.length > 8 ||
        jumpIds.contains(id) ||
        jumpIds.toSet().length != jumpIds.length) {
      throw const FormatException('跳板路径无效或形成循环');
    }
  }
}

class Credential {
  const Credential({
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
    this.useAgent = false,
  });
  final String password, privateKey, passphrase;
  final bool useAgent;
  Map<String, dynamic> toJson() => {
    'password': password,
    'privateKey': privateKey,
    'passphrase': passphrase,
    'useAgent': useAgent,
  };
  factory Credential.fromJson(Map<String, dynamic> j) => Credential(
    password: j['password'] as String? ?? '',
    privateKey: j['privateKey'] as String? ?? '',
    passphrase: j['passphrase'] as String? ?? '',
    useAgent: j['useAgent'] == true,
  );
}
