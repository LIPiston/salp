import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'host.dart';
import 'master_password.dart';
import 'session_log.dart';
import 'serial_profile.dart';
import 'vault_cipher.dart';

class Repository {
  Repository(this.directory, this.key);
  final Directory directory;
  final Uint8List key;
  final hosts = <Host>[];
  final credentials = <String, Credential>{};
  final knownHosts = <String, String>{};
  final snippets = <String, String>{};
  final serialProfiles = <String, Map<String, dynamic>>{};
  Map<String, String>? masterPassword;
  // Bootstrap credentials and merge history stay in the OS-key encrypted local vault.
  // Only syncEntries() is eligible for upload.
  Map<String, String> webDav = {};
  Map<String, dynamic> syncBase = {};
  Map<String, dynamic> syncBackup = {};
  String syncEndpoint = '';
  final mcpAgents = <Map<String, dynamic>>[];
  final hostHighlight = <String, Map<String, dynamic>>{};
  bool highlightEnabled = true;
  List<Map<String, dynamic>> highlightRules = [
    {'pattern': 'ERROR', 'color': 0xffe98686},
    {'pattern': 'WARN', 'color': 0xffe1c480},
  ];
  bool startupAuthentication = false;
  int autoLockMinutes = 15;
  bool locked = false;
  int epoch = 0;
  void checkAuthority(int captured) {
    if (locked || captured != epoch) throw StateError("授权上下文已失效");
  }

  bool _syncBusy = false;

  /// Shared across service instances: syncing, restoring and rewrapping a
  /// password may never race each other's network or local commits.
  Future<T> withSyncOperation<T>(Future<T> Function() action) async {
    if (_syncBusy) throw StateError('同步、恢复或主密码变更正在进行');
    _syncBusy = true;
    try {
      return await action();
    } finally {
      _syncBusy = false;
    }
  }

  Future<void> _writes = Future.value();
  static Future<Repository> open() async {
    final override = Platform.environment['SALP_DATA_DIR'];
    final directory = override == null
        ? await getApplicationSupportDirectory()
        : Directory(override);
    await directory.create(recursive: true);
    const storage = FlutterSecureStorage();
    const keyName = 'salp.v1.vault-key';
    var encoded = await storage.read(key: keyName);
    if (encoded == null) {
      if (await File('${directory.path}/vault.salp').exists()) {
        throw StateError('系统安全存储缺少解密密钥；现有保险库已保留');
      }
      encoded = base64.encode(VaultCipher.randomBytes(32));
      await storage.write(key: keyName, value: encoded);
    }
    final repo = Repository(directory, base64.decode(encoded));
    await repo.load();
    await SessionLog.prune(Directory('${directory.path}/logs'));
    return repo;
  }

  Future<void> load() async {
    final file = File('${directory.path}/vault.salp');
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final data = jsonDecode(
      utf8.decode(VaultCipher().open(bytes, key)),
    ) as Map<String, dynamic>;
    _restore(data);
  }

  Map<String, dynamic> _snapshot() => {
    'version': 1,
    'hosts': hosts.map((h) => h.toJson()).toList(),
    'credentials': credentials.map((k, v) => MapEntry(k, v.toJson())),
    'knownHosts': knownHosts,
    'snippets': snippets,
    'serialProfiles': serialProfiles,
    'masterPassword': masterPassword,
    'startupAuthentication': startupAuthentication,
    'autoLockMinutes': autoLockMinutes,
    'webDav': webDav,
    'syncBase': syncBase,
    'syncBackup': syncBackup,
    'syncEndpoint': syncEndpoint,
    'mcpAgents': mcpAgents,
    'highlightEnabled': highlightEnabled,
    'hostHighlight': hostHighlight,
    'highlightRules': highlightRules,
  };

  void _restore(Map<String, dynamic> data) {
    hosts
      ..clear()
      ..addAll(
        (data['hosts'] as List).map(
          (x) => Host.fromJson(Map<String, dynamic>.from(x as Map)),
        ),
      );
    credentials.clear();
    for (final entry in (data['credentials'] as Map).entries) {
      credentials[entry.key as String] = Credential.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
    knownHosts
      ..clear()
      ..addAll(Map<String, String>.from(data['knownHosts'] as Map));
    snippets
      ..clear()
      ..addAll(Map<String, String>.from(data['snippets'] as Map? ?? {}));
    serialProfiles
      ..clear()
      ..addAll(
        (data['serialProfiles'] as Map? ?? {}).map(
          (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
        ),
      );
    masterPassword = data['masterPassword'] == null
        ? null
        : Map<String, String>.from(data['masterPassword'] as Map);
    startupAuthentication = data['startupAuthentication'] == true;
    autoLockMinutes = data['autoLockMinutes'] as int? ?? 15;
    webDav = Map<String, String>.from(data['webDav'] as Map? ?? {});
    syncBase = Map<String, dynamic>.from(data['syncBase'] as Map? ?? {});
    syncBackup = Map<String, dynamic>.from(data['syncBackup'] as Map? ?? {});
    syncEndpoint = data['syncEndpoint'] as String? ?? '';
    hostHighlight
      ..clear()
      ..addAll(
        (data['hostHighlight'] as Map? ?? {}).map(
          (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
        ),
      );
    highlightEnabled = data['highlightEnabled'] != false;
    if (data['highlightRules'] is List) {
      highlightRules = (data['highlightRules'] as List)
          .map((j) => Map<String, dynamic>.from(j as Map))
          .toList();
    }
    mcpAgents
      ..clear()
      ..addAll(
        (data['mcpAgents'] as List? ?? []).map(
          (j) => Map<String, dynamic>.from(j as Map),
        ),
      );
  }

  /// Serialize the entire change, not just writes. Readers retain the last
  /// committed state while a detached draft is being encrypted and flushed.
  /// The callback must be synchronous and must only change its draft.
  Future<void> update(
    void Function(Repository draft) change, {
    int? authority,
  }) {
    final captured = authority ?? epoch;
    final write = _writes.then((_) async {
      checkAuthority(captured);
      final draft = Repository(directory, key);
      draft._restore(
        jsonDecode(jsonEncode(_snapshot())) as Map<String, dynamic>,
      );
      change(draft);
      final data = draft._snapshot();
      final bytes = VaultCipher().seal(
        Uint8List.fromList(utf8.encode(jsonEncode(data))),
        key,
      );
      final temporary = File('${directory.path}/vault.pending');
      await temporary.writeAsBytes(bytes, flush: true);
      // No await between authority check, rename and publishing memory: a lock
      // cannot run in the middle of this commit on the Dart event loop.
      try {
        checkAuthority(captured);
        temporary.renameSync('${directory.path}/vault.salp');
      } catch (_) {
        if (temporary.existsSync()) temporary.deleteSync();
        rethrow;
      }
      _restore(data);
    });
    // A failed transaction must not poison the queue or become unhandled here.
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  /// Persist initial in-memory data. Runtime edits use update() so uncommitted
  /// data is never shared with connections or another pending transaction.
  Future<void> save() {
    final data = jsonDecode(jsonEncode(_snapshot())) as Map<String, dynamic>;
    return update((draft) => draft._restore(data));
  }

  Future<void> setStartupAuthentication(
    bool enabled,
    String password,
    int authority,
  ) async {
    checkAuthority(authority);
    final verifier = masterPassword;
    if (verifier == null || !await MasterPassword.verify(password, verifier)) {
      throw StateError('当前主密码不正确');
    }
    checkAuthority(authority);
    await update((draft) {
      if (jsonEncode(draft.masterPassword) != jsonEncode(verifier)) {
        throw StateError('主密码已变更，请重新验证');
      }
      draft.startupAuthentication = enabled;
    }, authority: authority);
  }

  Future<void> upsert(Host host, Credential credential) {
    host.validate();
    return update((draft) {
      final index = draft.hosts.indexWhere((h) => h.id == host.id);
      if (index < 0) {
        draft.hosts.add(host);
      } else {
        draft.hosts[index] = host;
      }
      draft.credentials[host.id] = credential;
    });
  }

  Future<void> saveSerialProfile(
    String name,
    SerialSettings settings,
    int authority,
  ) async {
    checkAuthority(authority);
    settings.validate();
    final label = name.trim();
    if (label.isEmpty ||
        label.length > 100 ||
        label.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('配置名称必须为1–100字符且不含控制字符');
    }
    await update((draft) {
      if (!draft.serialProfiles.containsKey(label) &&
          draft.serialProfiles.length >= 100) {
        throw StateError('最多保存100份串口配置');
      }
      draft.serialProfiles[label] = settings.toJson();
    }, authority: authority);
  }

  Future<void> removeSerialProfile(String name, int authority) => update(
    (draft) => draft.serialProfiles.remove(name),
    authority: authority,
  );

  Map<String, dynamic> syncEntries() => {
    for (final host in hosts)
      'host:${host.id}': {
        'host': host.toJson(),
        'credential': (credentials[host.id] ?? const Credential()).toJson(),
      },
    for (final entry in snippets.entries) 'snippet:${entry.key}': entry.value,
  };

  static void validateSyncEntries(Map<String, dynamic> entries) {
    final hosts = <String, Host>{};
    if (entries.length > 20000) throw const FormatException('同步条目过多');
    for (final entry in entries.entries) {
      if (entry.key.startsWith('host:')) {
        final value = Map<String, dynamic>.from(entry.value as Map);
        final host = Host.fromJson(
          Map<String, dynamic>.from(value['host'] as Map),
        );
        host.validate();
        if (entry.key != 'host:${host.id}') {
          throw const FormatException('主机身份不匹配');
        }
        Credential.fromJson(
          Map<String, dynamic>.from(value['credential'] as Map),
        );
        hosts[host.id] = host;
      } else if (!entry.key.startsWith('snippet:') || entry.value is! String) {
        throw const FormatException('未知同步条目，不会覆盖本地数据');
      }
    }
    for (final host in hosts.values) {
      if (host.jumpIds.any((id) => !hosts.containsKey(id))) {
        throw const FormatException('同步主机引用了缺失的跳板，请保留相应跳板或修改主机');
      }
    }
  }

  void _replaceSyncEntries(Map<String, dynamic> entries) {
    hosts.clear();
    credentials.clear();
    snippets.clear();
    for (final entry in entries.entries) {
      if (entry.key.startsWith('host:')) {
        final value = Map<String, dynamic>.from(entry.value as Map);
        final host = Host.fromJson(
          Map<String, dynamic>.from(value['host'] as Map),
        );
        hosts.add(host);
        credentials[host.id] = Credential.fromJson(
          Map<String, dynamic>.from(value['credential'] as Map),
        );
      } else {
        snippets[entry.key.substring('snippet:'.length)] =
            entry.value as String;
      }
    }
  }

  Future<void> applySync(
    Map<String, dynamic> entries, {
    required Map<String, dynamic> base,
    required String endpoint,
    required Map<String, dynamic> backup,
    required int authority,
    Map<String, String>? verifier,
    Map<String, dynamic>? expected,
  }) async {
    checkAuthority(authority);
    validateSyncEntries(entries);
    await update((draft) {
      if (expected != null &&
          !const DeepCollectionEquality().equals(
            expected,
            draft.syncEntries(),
          )) {
        throw StateError('本地配置已修改，请重新生成同步预览');
      }
      draft._replaceSyncEntries(entries);
      if (verifier != null) draft.masterPassword = verifier;
      draft.syncBase = base;
      draft.syncBackup = backup;
      draft.syncEndpoint = endpoint;
    }, authority: authority);
  }

  /// Restore only the synchronized records. Trust, agents and sync ancestry
  /// remain local; the next remote update still needs a fresh merge preview.
  Future<void> restoreSyncBackup({
    required String version,
    required String password,
    required int authority,
    required Map<String, dynamic> expectedEntries,
    required Map<String, dynamic> expectedBackup,
  }) => withSyncOperation(() async {
    checkAuthority(authority);
    final expected =
        jsonDecode(jsonEncode(expectedEntries)) as Map<String, dynamic>;
    final backup =
        jsonDecode(jsonEncode(expectedBackup)) as Map<String, dynamic>;
    if (!{'local', 'remote', 'undo'}.contains(version) ||
        backup[version] is! Map) {
      throw const FormatException('所选备份不存在');
    }
    final verifier = masterPassword;
    if (verifier == null || !await MasterPassword.verify(password, verifier)) {
      throw StateError('当前主密码不正确');
    }
    checkAuthority(authority);
    final entries = Map<String, dynamic>.from(backup[version] as Map);
    validateSyncEntries(entries);
    await update((draft) {
      const equality = DeepCollectionEquality();
      if (!equality.equals(draft.masterPassword, verifier) ||
          !equality.equals(draft.syncEntries(), expected) ||
          !equality.equals(draft.syncBackup, backup)) {
        throw StateError('本地数据、备份或主密码已变化，请重新预览');
      }
      draft.syncBackup = {
        ...backup,
        'undo': draft.syncEntries(),
        'restoredAt': DateTime.now().toUtc().toIso8601String(),
      };
      draft._replaceSyncEntries(entries);
    }, authority: authority);
  });

  Host host(String id) => hosts.firstWhere((h) => h.id == id);
}
