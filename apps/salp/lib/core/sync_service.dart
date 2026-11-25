import 'package:collection/collection.dart';

import 'repository.dart';
import 'sync.dart';
import 'master_password.dart';

class PreparedSync {
  PreparedSync._(
    this.owner,
    this.authority,
    this.local,
    this.remote,
    this.vault,
    this.etag,
    this.password,
    this.merge,
    this.verifier,
    this.base,
    this.endpoint,
  );
  final SyncService owner;
  final Map<String, String>? verifier;
  final Map<String, dynamic> base;
  final String endpoint;
  final int authority;
  final Map<String, dynamic> local, remote;
  final SyncVault vault;
  final String? etag;
  String password;
  final SyncMerge merge;
  bool consumed = false;
  Map<String, String>? nextVerifier;
  void forget() {
    password = '';
    consumed = true;
  }
}

class SyncService {
  SyncService(this.repository, this.client);
  final Repository repository;
  final WebDavClient client;
  bool _busy = false;

  Future<PreparedSync> prepare(String password, {String? localPassword}) =>
      repository.withSyncOperation(
        () => _prepare(password, localPassword: localPassword),
      );

  Future<PreparedSync> _prepare(
    String password, {
    String? localPassword,
  }) async {
    if (_busy) throw StateError('同步正在进行');
    _busy = true;
    final authority = repository.epoch;
    try {
      repository.checkAuthority(authority);
      final verifier = repository.masterPassword;
      if (verifier != null &&
          !await MasterPassword.verify(localPassword ?? password, verifier)) {
        throw const SyncException('本机主密码不正确');
      }
      repository.checkAuthority(authority);
      final local = repository.syncEntries();
      Repository.validateSyncEntries(local);
      final base = repository.syncEndpoint == client.uri.toString()
          ? repository.syncBase
          : <String, dynamic>{};
      final remote = await client.fetch();
      repository.checkAuthority(authority);
      if (remote == null && base.isNotEmpty) {
        throw const SyncException('远端保险库缺失；已停止同步，本地数据保留。请检查地址和服务器备份');
      }
      final vault = remote == null
          ? await SyncVault.create({}, password)
          : await SyncVault.open(remote.bytes, password);
      repository.checkAuthority(authority);
      Repository.validateSyncEntries(vault.entries);
      final prepared = PreparedSync._(
        this,
        authority,
        local,
        vault.entries,
        vault,
        remote?.etag,
        password,
        SyncMerge(base: base, local: local, remote: vault.entries),
        verifier == null ? null : Map.of(verifier),
        Map.of(repository.syncBase),
        repository.syncEndpoint,
      );
      if (localPassword != null && localPassword != password) {
        prepared.nextVerifier = await MasterPassword.create(password);
        repository.checkAuthority(authority);
      }
      return prepared;
    } finally {
      _busy = false;
    }
  }

  Future<void> commit(PreparedSync prepared, Map<String, SyncChoice> choices) =>
      repository.withSyncOperation(() => _commit(prepared, choices));

  Future<void> _commit(
    PreparedSync prepared,
    Map<String, SyncChoice> choices,
  ) async {
    if (_busy || prepared.owner != this || prepared.consumed) {
      throw StateError('此同步预览已失效');
    }
    void check() {
      repository.checkAuthority(prepared.authority);
      const equality = DeepCollectionEquality();
      if (!equality.equals(prepared.verifier, repository.masterPassword) ||
          !equality.equals(prepared.base, repository.syncBase) ||
          prepared.endpoint != repository.syncEndpoint) {
        throw StateError('主密码或同步历史已变化，请重新生成预览');
      }
      if (!const DeepCollectionEquality().equals(
        prepared.local,
        repository.syncEntries(),
      )) {
        throw StateError('本地配置已修改，请重新生成同步预览');
      }
    }

    check();
    final resolved = prepared.merge.resolve(choices);
    Repository.validateSyncEntries(resolved);
    _busy = true;
    try {
      final sealed = await prepared.vault.seal(resolved, prepared.password);
      check();
      // Persist both versions before any remote replacement, including crashes.
      final backup = <String, dynamic>{
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'endpoint': client.uri.toString(),
        'local': prepared.local,
        'remote': prepared.remote,
      };
      await repository.update((draft) {
        check();
        draft.syncBackup = backup;
      }, authority: prepared.authority);
      check();
      await client.verifyConditionalWrites();
      check();
      prepared.consumed = true;
      await client.put(sealed.bytes, etag: prepared.etag);
      check();
      await repository.applySync(
        resolved,
        base: resolved,
        endpoint: client.uri.toString(),
        backup: backup,
        authority: prepared.authority,
        verifier: prepared.nextVerifier,
        expected: prepared.local,
      );
    } finally {
      prepared.password = '';
      _busy = false;
    }
  }
}

/// Rewrap the existing remote data key without merging or replacing its entries.
/// If local persistence fails after remote success, the next sync can authenticate
/// with the old local password and the new remote password to finish adoption.
Future<void> changeMasterPassword(
  Repository repo,
  String? previous,
  String next,
) => repo.withSyncOperation(() => _changeMasterPassword(repo, previous, next));

Future<void> _changeMasterPassword(
  Repository repo,
  String? previous,
  String next,
) async {
  final authority = repo.epoch;
  final oldVerifier = repo.masterPassword;
  repo.checkAuthority(authority);
  if (oldVerifier != null &&
      (previous == null ||
          !await MasterPassword.verify(previous, oldVerifier))) {
    throw const SyncException('当前主密码不正确');
  }
  final verifier = await MasterPassword.create(next);
  repo.checkAuthority(authority);
  if (repo.webDav['url']?.isNotEmpty == true && previous != null) {
    final client = WebDavClient(
      Uri.parse(repo.webDav['url']!),
      repo.webDav['username'] ?? '',
      repo.webDav['password'] ?? '',
    );
    try {
      final remote = await client.fetch();
      repo.checkAuthority(authority);
      if (remote == null && repo.syncBase.isNotEmpty) {
        throw const SyncException('远端保险库缺失，未更改主密码');
      }
      if (remote != null) {
        final vault = await SyncVault.open(remote.bytes, previous);
        final sealed = await vault.seal(vault.entries, next);
        repo.checkAuthority(authority);
        await client.verifyConditionalWrites();
        repo.checkAuthority(authority);
        await client.put(sealed.bytes, etag: remote.etag);
        repo.checkAuthority(authority);
      }
    } finally {
      client.close();
    }
  }
  try {
    await repo.update((draft) {
      if (!const DeepCollectionEquality().equals(
        draft.masterPassword,
        oldVerifier,
      )) {
        throw StateError('主密码已变更，请重新验证');
      }
      draft.masterPassword = verifier;
    }, authority: authority);
  } catch (_) {
    throw const SyncException('本地主密码保存未完成；如果远端已更新，请用旧本机密码和新远端密码同步恢复');
  }
}
