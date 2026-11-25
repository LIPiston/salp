import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'master_password.dart';
import 'vault_cipher.dart';

class SyncException implements Exception {
  const SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncRemoteChanged extends SyncException {
  const SyncRemoteChanged() : super('远端已被其他设备修改；请重新拉取并处理冲突');
}

enum SyncChoice { local, remote }

class SyncConflict {
  const SyncConflict(this.key, this.local, this.remote);
  final String key;
  final Object? local, remote;
}

/// A missing entry is a deletion only relative to the last successful sync.
/// The complete snapshots stay intact until every conflicting key is resolved.
class SyncMerge {
  SyncMerge({
    required Map<String, dynamic> base,
    required Map<String, dynamic> local,
    required Map<String, dynamic> remote,
  }) {
    const equality = DeepCollectionEquality();
    for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
      final b = base[key], l = local[key], r = remote[key];
      Object? chosen;
      if (equality.equals(l, r) || equality.equals(r, b)) {
        chosen = l;
      } else if (equality.equals(l, b)) {
        chosen = r;
      } else {
        conflicts.add(SyncConflict(key, l, r));
        continue;
      }
      if (chosen != null) merged[key] = chosen;
    }
  }
  final merged = <String, dynamic>{};
  final conflicts = <SyncConflict>[];
  Map<String, dynamic> resolve(Map<String, SyncChoice> choices) {
    final result = {...merged};
    for (final conflict in conflicts) {
      final choice = choices[conflict.key];
      if (choice == null) throw StateError('请为每个冲突选择保留版本');
      final value = choice == SyncChoice.local
          ? conflict.local
          : conflict.remote;
      if (value != null) result[conflict.key] = value;
    }
    return result;
  }
}

/// Random data key, wrapped with a password-derived key; no clear host metadata.
/// KDF parameters are fixed by the format, never taken from an untrusted server.
class SyncVault {
  SyncVault._(this.entries, this.dataKey, this.bytes);
  final Map<String, dynamic> entries;
  final Uint8List dataKey, bytes;
  static Future<SyncVault> create(
    Map<String, dynamic> entries,
    String password,
  ) => SyncVault._(
    {},
    VaultCipher.randomBytes(32),
    Uint8List(0),
  ).seal(entries, password);

  Future<SyncVault> seal(Map<String, dynamic> entries, String password) async {
    if (password.length < 8) throw const FormatException('主密码至少需要 8 个字符');
    final salt = VaultCipher.randomBytes(16);
    final key = await MasterPassword.deriveKey(password, salt);
    try {
      final cipher = VaultCipher();
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'salp-sync-1',
            'kdf': 'argon2id-v1',
            'salt': base64.encode(salt),
            'wrappedKey': base64.encode(cipher.seal(dataKey, key)),
            'payload': base64.encode(
              cipher.seal(
                Uint8List.fromList(utf8.encode(jsonEncode(entries))),
                dataKey,
              ),
            ),
          }),
        ),
      );
      if (bytes.length > WebDavClient.maxBytes) {
        throw const SyncException('同步保险库超过 16 MiB 上限');
      }
      return SyncVault._(entries, dataKey, bytes);
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  static Future<SyncVault> open(Uint8List bytes, String password) async {
    if (bytes.length > WebDavClient.maxBytes) {
      throw const SyncException('同步保险库过大');
    }
    try {
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (envelope['format'] != 'salp-sync-1' ||
          envelope['kdf'] != 'argon2id-v1') {
        throw const FormatException('不支持的同步保险库版本');
      }
      final salt = base64.decode(envelope['salt'] as String);
      if (salt.length != 16) throw const FormatException('盐长度错误');
      final key = await MasterPassword.deriveKey(password, salt);
      try {
        final cipher = VaultCipher();
        final dataKey = cipher.open(
          base64.decode(envelope['wrappedKey'] as String),
          key,
        );
        final data = jsonDecode(
          utf8.decode(
            cipher.open(base64.decode(envelope['payload'] as String), dataKey),
          ),
        );
        return SyncVault._(
          Map<String, dynamic>.from(data as Map),
          dataKey,
          bytes,
        );
      } finally {
        key.fillRange(0, key.length, 0);
      }
    } catch (_) {
      throw const SyncException('主密码不正确或远端保险库损坏；本地数据未修改');
    }
  }
}

class RemoteVault {
  const RemoteVault(this.bytes, this.etag);
  final Uint8List bytes;
  final String etag;
}

class WebDavClient {
  WebDavClient(this.uri, String username, String password)
    : _authorization =
          'Basic ${base64.encode(utf8.encode('$username:$password'))}' {
    final loopback = InternetAddress.tryParse(uri.host)?.isLoopback == true;
    if ((uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        username.contains(':')) {
      throw const FormatException('请使用不含账号信息的 HTTPS 文件地址（本机测试可用 HTTP）');
    }
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.autoUncompress = false;
  }
  static const maxBytes = 16 * 1024 * 1024;
  static const _timeout = Duration(seconds: 30);
  final Uri uri;
  final String _authorization;
  final _client = HttpClient();

  Future<HttpClientRequest> _request(String method, [Uri? target]) async {
    final request = await _client
        .openUrl(method, target ?? uri)
        .timeout(_timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, _authorization);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    return request;
  }

  String _etag(HttpClientResponse response) {
    final tag = response.headers.value(HttpHeaders.etagHeader);
    if (tag == null || !RegExp(r'^"[^"\x00-\x20\x7f]*"$').hasMatch(tag)) {
      throw const SyncException('服务器未提供强 ETag，已停止同步以防覆盖冲突');
    }
    return tag;
  }

  Future<void> _cancelResponse(HttpClientResponse response) async {
    await response.listen((_) {}).cancel();
  }

  // Probe only a fresh random sibling object, never the user's vault.
  // A server which ignores preconditions must be rejected before a real PUT.
  Future<void> verifyConditionalWrites() async {
    final suffix = base64Url.encode(VaultCipher.randomBytes(18));
    final probe = uri.replace(path: '${uri.path}.salp-check-$suffix');
    var created = false;
    String? tag;
    try {
      Future<int> put(String header, String value) async {
        final request = await _request('PUT', probe);
        request.headers.set(header, value);
        final bytes = VaultCipher.randomBytes(32);
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close().timeout(_timeout);
        try {
          if ([200, 201, 204].contains(response.statusCode)) {
            created = true;
            tag = _etag(response);
          }
          return response.statusCode;
        } finally {
          await _cancelResponse(response);
        }
      }

      if (![
            200,
            201,
            204,
          ].contains(await put(HttpHeaders.ifNoneMatchHeader, '*')) ||
          await put(HttpHeaders.ifNoneMatchHeader, '*') != 412 ||
          await put(HttpHeaders.ifMatchHeader, '"salp-impossible-$suffix"') !=
              412) {
        throw const SyncException('服务器未遵守条件写入，已停止同步；不会覆盖保险库');
      }
    } finally {
      if (created) {
        final request = await _request('DELETE', probe);
        if (tag != null) request.headers.set(HttpHeaders.ifMatchHeader, tag!);
        final response = await request.close().timeout(_timeout);
        final status = response.statusCode;
        await _cancelResponse(response);
        if (![200, 204, 404].contains(status)) {
          throw const SyncException('同步检查文件清理失败；已停止同步，请检查 WebDAV 写入和删除权限');
        }
      }
    }
  }

  Future<RemoteVault?> fetch() async {
    final request = await _request('GET');
    try {
      final response = await request.close().timeout(_timeout);
      if (response.statusCode == 404) {
        await _cancelResponse(response);
        return null;
      }
      if (response.statusCode != 200) {
        await _cancelResponse(response);
        throw SyncException('拉取失败（HTTP ${response.statusCode}），本地数据未修改');
      }
      String etag;
      try {
        etag = _etag(response);
        if (response.contentLength > maxBytes) {
          throw const SyncException('远端保险库超过 16 MiB 上限');
        }
      } catch (_) {
        await _cancelResponse(response);
        rethrow;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_timeout)) {
        if (builder.length + chunk.length > maxBytes) {
          throw const SyncException('远端保险库超过 16 MiB 上限');
        }
        builder.add(chunk);
      }
      return RemoteVault(builder.takeBytes(), etag);
    } catch (_) {
      request.abort();
      rethrow;
    }
  }

  Future<String> put(Uint8List bytes, {required String? etag}) async {
    if (bytes.length > maxBytes) throw const SyncException('同步保险库过大');
    if (etag != null && !RegExp(r'^"[^"\x00-\x20\x7f]*"$').hasMatch(etag)) {
      throw const SyncException('缺少有效的强 ETag，拒绝覆盖');
    }
    final request = await _request('PUT');
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/octet-stream',
    );
    request.headers.set(
      etag == null ? HttpHeaders.ifNoneMatchHeader : HttpHeaders.ifMatchHeader,
      etag ?? '*',
    );
    request.contentLength = bytes.length;
    request.add(bytes);
    try {
      final response = await request.close().timeout(_timeout);
      try {
        if (response.statusCode == 412) throw const SyncRemoteChanged();
        if (![200, 201, 204].contains(response.statusCode)) {
          throw SyncException('上传未确认（HTTP ${response.statusCode}）；请重新拉取核对');
        }
        return _etag(response);
      } finally {
        await _cancelResponse(response);
      }
    } catch (_) {
      request.abort();
      rethrow;
    }
  }

  void close() => _client.close(force: true);
}
