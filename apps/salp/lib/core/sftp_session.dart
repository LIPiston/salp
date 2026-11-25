import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';

import 'connection.dart';
import 'host.dart';
import 'repository.dart';
import 'local_commit.dart';
import 'android_documents.dart';

import 'package:flutter/services.dart';

enum ConflictChoice { skip, keepBoth }

enum TransferState { queued, running, complete, cancelled, failed }

typedef ConflictPrompt = Future<ConflictChoice> Function(String name);

Uint8List remoteChild(Uint8List directory, List<int> name) {
  if (name.isEmpty ||
      name.contains(0) ||
      name.contains(47) ||
      listEquals(name, [46]) ||
      listEquals(name, [46, 46])) {
    throw const FormatException('无效远端文件名');
  }
  return Uint8List.fromList([
    ...directory,
    if (directory.isEmpty || directory.last != 47) 47,
    ...name,
  ]);
}

String remoteLabel(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return bytes
        .map(
          (b) => b >= 32 && b < 127
              ? String.fromCharCode(b)
              : '\\x${b.toRadixString(16).padLeft(2, '0')}',
        )
        .join();
  }
}

class TransferJob {
  TransferJob(this.name, this.upload, this.run);
  final String name;
  final bool upload;
  final Future<void> Function(TransferJob) run;
  TransferState state = TransferState.queued;
  int bytes = 0;
  int? total;
  String? error;
  bool cancelled = false;
  void check() {
    if (cancelled) throw const _Cancelled();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class SftpSession extends ChangeNotifier {
  SftpSession(this.host);
  final Host host;
  SshConnection? connection;
  SftpClient? client;
  Uint8List path = Uint8List.fromList([46]);
  List<SftpName> entries = [];
  final jobs = <TransferJob>[];
  String status = '连接中';
  String? error;
  bool loading = false, closed = false, locked = false, _running = false;
  int _listing = 0;
  int _authority = 0;
  Future<void> open(
    Repository repo,
    VerifyHost verify,
    PromptAuth prompt,
  ) async {
    final authority = repo.epoch;
    final generation = _authority;
    void check() {
      repo.checkAuthority(authority);
      if (closed || locked || generation != _authority) {
        throw StateError('文件连接上下文已失效');
      }
    }

    try {
      check();
      connection = await SshConnection.connect(repo, host, verify, prompt);
      if (closed) {
        await connection!.close();
        return;
      }
      check();
      client = await connection!.client.sftp();
      check();
      path = await client!.absoluteBytes('.');
      check();
      status = '已连接';
      await list(path);
    } catch (e) {
      await client?.close();
      await connection?.close();
      status = '连接失败';
      error = e is TrustSaved ? e.toString() : 'SFTP 连接失败，请检查凭据和主机密钥';
    }
    notifyListeners();
  }

  void guard() {
    if (closed || locked || client == null) throw StateError('文件会话不可用');
  }

  /// Captures the session and directory a user action was started in. A picker
  /// or confirmation from before a lock/navigation must not authorize new work.
  void Function() captureAction() {
    guard();
    final authority = _authority;
    final directory = Uint8List.fromList(path);
    return () {
      guard();
      if (authority != _authority || !listEquals(path, directory)) {
        throw StateError('文件操作上下文已变化，请重新选择');
      }
    };
  }

  Future<void> list(Uint8List target) async {
    guard();
    final request = ++_listing;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final found = <SftpName>[];
      await for (final batch in client!.readdir(target)) {
        if (closed || locked || request != _listing) return;
        found.addAll(
          batch.where(
            (e) =>
                !listEquals(e.filenameBytes, [46]) &&
                !listEquals(e.filenameBytes, [46, 46]),
          ),
        );
        if (found.length > 10000) throw StateError('目录超过 10000 项上限，请进入较小的子目录');
      }
      found.sort((a, b) {
        if (a.attr.isDirectory != b.attr.isDirectory) {
          return a.attr.isDirectory ? -1 : 1;
        }
        return remoteLabel(a.filenameBytes)
            .compareTo(remoteLabel(b.filenameBytes));
      });
      if (request == _listing && !closed && !locked) {
        entries = found;
        path = Uint8List.fromList(target);
      }
    } catch (_) {
      if (request == _listing) {
        error = '目录读取失败或超过 10000 项上限';
        entries = [];
      }
    } finally {
      if (request == _listing) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> parent() async {
    final slash = path.lastIndexOf(47, path.length > 1 ? path.length - 2 : 0);
    await list(Uint8List.fromList(slash <= 0 ? [47] : path.sublist(0, slash)));
  }

  Future<Uint8List> preview(SftpName entry) async {
    guard();
    final authority = _authority;
    if (entry.attr.isSymbolicLink) throw StateError('预览不跟随符号链接');
    final file = await client!.open(remoteChild(path, entry.filenameBytes));
    try {
      if (((await file.stat()).size ?? 0) > 1048576) {
        throw StateError('预览上限为 1 MiB');
      }
      final bytes = await file.readBytes(length: 1048577);
      if (bytes.length > 1048576) throw StateError('预览上限为 1 MiB');
      guard();
      if (authority != _authority) throw StateError('预览上下文已失效，请重新打开');
      return bytes;
    } finally {
      await file.close();
    }
  }

  Future<void> mkdir(String name) async {
    guard();
    await client!.mkdir(remoteChild(path, utf8.encode(name)));
    await list(path);
  }

  Future<void> rename(SftpName entry, String name) async {
    guard();
    await client!.renameNoReplace(
      remoteChild(path, entry.filenameBytes),
      remoteChild(path, utf8.encode(name)),
    );
    await list(path);
  }

  Future<void> remove(SftpName entry) async {
    guard();
    final target = remoteChild(path, entry.filenameBytes);
    if (entry.attr.isDirectory && !entry.attr.isSymbolicLink) {
      await client!.rmdir(target);
    } else {
      await client!.remove(target);
    }
    await list(path);
  }

  void enqueue(TransferJob job) {
    guard();
    if (jobs
            .where(
              (j) =>
                  j.state == TransferState.queued ||
                  j.state == TransferState.running,
            )
            .length >=
        128) {
      throw StateError('传输队列已满');
    }
    jobs.add(job);
    notifyListeners();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (!closed && !locked) {
        final queued = jobs
            .where((j) => j.state == TransferState.queued)
            .firstOrNull;
        if (queued == null) break;
        queued.state = TransferState.running;
        notifyListeners();
        try {
          queued.check();
          await queued.run(queued);
          queued.state = TransferState.complete;
        } on _Cancelled {
          queued.state = TransferState.cancelled;
        } catch (_) {
          queued.state = TransferState.failed;
          queued.error = '传输失败，可重试；现有目标文件未覆盖';
        }
        notifyListeners();
      }
    } finally {
      _running = false;
    }
  }

  void cancel(TransferJob job) {
    job.cancelled = true;
    if (job.state == TransferState.queued) job.state = TransferState.cancelled;
    notifyListeners();
  }

  void retry(TransferJob job) {
    guard();
    if (job.state != TransferState.failed &&
        job.state != TransferState.cancelled) {
      throw StateError("此任务不能重试");
    }
    job.cancelled = false;
    job.bytes = 0;
    job.error = null;
    job.state = TransferState.queued;
    unawaited(_drain());
    notifyListeners();
  }

  Future<bool> _exists(Uint8List target) async {
    try {
      await client!.stat(target, followLink: false);
      return true;
    } on SftpStatusError catch (e) {
      if (e.code == 2) return false;
      rethrow;
    }
  }

  void upload(PlatformFile local, ConflictPrompt conflict) {
    final directory = Uint8List.fromList(path);
    enqueue(
      TransferJob(local.name, true, (job) async {
        guard();
        job.total = await local.length();
        var target = remoteChild(directory, utf8.encode(local.name));
        if (await _exists(target)) {
          if (await conflict(local.name) == ConflictChoice.skip) {
            throw const _Cancelled();
          }
          target = remoteChild(
            directory,
            utf8.encode('${local.name}.copy-${Host.newId()}'),
          );
        }
        job.check();
        guard();
        final temporary = remoteChild(
          directory,
          utf8.encode('.salp-${Host.newId()}.part'),
        );
        final output = await client!.open(
          temporary,
          mode:
              SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.exclusive,
        );
        var committed = false;
        try {
          await for (final chunk in local.readAsByteStream()) {
            job.check();
            guard();
            await output.writeBytes(
              chunk,
              offset: job.bytes,
              maxPendingRequests: 2,
            );
            job.bytes += chunk.length;
            notifyListeners();
          }
          await output.close();
          job.check();
          guard();
          await client!.renameNoReplace(temporary, target);
          committed = true;
        } finally {
          await output.close();
          if (!committed) {
            try {
              await client!.remove(temporary);
            } catch (_) {}
          }
        }
        if (listEquals(path, directory)) await list(path);
      }),
    );
  }

  void download(SftpName entry, String directory, ConflictPrompt conflict) {
    final remote = remoteChild(path, entry.filenameBytes);
    final name = remoteLabel(entry.filenameBytes)
        .replaceAll(RegExp(r'[/\\\x00]'), '_');
    enqueue(
      TransferJob(name, false, (job) async {
        guard();
        if (entry.attr.isSymbolicLink) throw StateError('下载不跟随符号链接');
        var target = File('$directory/$name');
        if (await target.exists()) {
          if (await conflict(name) == ConflictChoice.skip) {
            throw const _Cancelled();
          }
          target = File('$directory/$name.copy-${Host.newId()}');
        }
        job.check();
        guard();
        final temporary = File('$directory/.salp-${Host.newId()}.part');
        await temporary.create(exclusive: true);
        final output = await temporary.open(mode: FileMode.writeOnly);
        SftpFile? source;
        var outputClosed = false;
        var committed = false;
        try {
          source = await client!.open(remote);
          job.total = (await source.stat()).size;
          await for (final chunk in source.read(maxPendingRequests: 2)) {
            job.check();
            guard();
            await output.writeFrom(chunk);
            job.bytes += chunk.length;
            notifyListeners();
          }
          await output.flush();
          await output.close();
          outputClosed = true;
          job.check();
          guard();
          await commitNoReplace(temporary, target);
          committed = true;
        } finally {
          await source?.close();
          if (!outputClosed) await output.close();
          if (!committed && await temporary.exists()) await temporary.delete();
        }
      }),
    );
  }

  void downloadAndroid(
    SftpName entry,
    String directory,
    ConflictPrompt conflict,
  ) {
    final remote = remoteChild(path, entry.filenameBytes);
    final name = remoteLabel(entry.filenameBytes)
        .replaceAll(RegExp(r'[/\\\x00]'), '_');
    enqueue(
      TransferJob(name, false, (job) async {
        guard();
        job.check();
        if (entry.attr.isSymbolicLink) throw StateError('下载不跟随符号链接');
        String? document;
        SftpFile? source;
        var committed = false;
        try {
          try {
            document = await AndroidDocuments.create(directory, name);
          } on PlatformException catch (e) {
            if (e.code != 'conflict') rethrow;
            if (await conflict(name) == ConflictChoice.skip) {
              throw const _Cancelled();
            }
            job.check();
            guard();
            document = await AndroidDocuments.create(
              directory,
              name,
              keepBoth: true,
            );
          }
          job.check();
          guard();
          source = await client!.open(remote);
          job.total = (await source.stat()).size;
          await for (final chunk in source.read(maxPendingRequests: 2)) {
            job.check();
            guard();
            await AndroidDocuments.write(document, chunk);
            job.bytes += chunk.length;
            notifyListeners();
          }
          job.check();
          guard();
          await AndroidDocuments.finish(document);
          committed = true;
        } finally {
          await source?.close();
          if (document != null && !committed) {
            await AndroidDocuments.abort(document);
          }
        }
      }),
    );
  }

  void setLocked(bool value) {
    _authority++;
    locked = value;
    if (value) {
      _listing++;
      loading = false;
      for (final job in jobs) {
        if (job.state == TransferState.running ||
            job.state == TransferState.queued) {
          cancel(job);
        }
      }
    }
    notifyListeners();
  }

  Future<void> close() async {
    _authority++;
    for (final job in jobs) {
      cancel(job);
    }
    closed = true;
    await client?.close();
    await connection?.close();
    status = '已关闭';
    notifyListeners();
  }
}
