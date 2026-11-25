import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pointycastle/export.dart';

import 'connection.dart';
import 'host.dart';

/// Independent SSH/SFTP channels owned by a visible agent terminal. File bytes
/// cross MCP directly; no tool can name a local filesystem path.
class McpOperations {
  final commands = <String, _Command>{};
  int _starting = 0;
  final _uploads = <String, _Upload>{};

  Future<Map<String, dynamic>> call(
    String tool,
    Map<String, dynamic> args,
    TerminalSession terminal,
    int authority,
    void Function() authorize,
  ) async {
    authorize();
    if (tool == 'exec_read' || tool == 'exec_close') {
      final id = args['commandId'];
      final command = commands[id];
      if (command == null) throw StateError('命令不属于此代理会话');
      if (tool == 'exec_close') {
        commands.remove(id);
        command.close();
        return {'closed': true, 'remoteOutcome': '关闭通道不保证远端进程已停止'};
      }
      return command.snapshot(
        args['stdoutOffset'] as int? ?? args['offset'] as int? ?? 0,
        args['stderrOffset'] as int? ?? args['offset'] as int? ?? 0,
      );
    }
    final ssh = terminal.ssh;
    if (ssh == null || !terminal.connected || terminal.closed) {
      throw StateError('结构化操作需要已连接的 SSH 专用会话');
    }
    if (tool == 'exec_start') {
      if (commands.length + _starting >= 16) throw StateError('请关闭旧命令，最多保留16个');
      final text = args['command'] as String;
      if (text.isEmpty ||
          utf8.encode(text).length > 32768 ||
          text.contains('\x00')) {
        throw const FormatException('命令必须为1–32768字节且不含NUL');
      }
      _starting++;
      var valid = true;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      void check() {
        authorize();
        if (!valid || DateTime.now().isAfter(deadline)) {
          throw StateError('命令提交超时，结果未知；不会自动重试');
        }
      }

      try {
        final session = await ssh.client.execute(text, authorize: check);
        try {
          check();
        } catch (_) {
          session.channel.destroy();
          rethrow;
        }
        final id = Host.newId();
        commands[id] = _Command(session);
        return {
          'commandId': id,
          'status': '已提交，使用exec_read读取结果',
          'untrusted': true,
        };
      } finally {
        valid = false;
        _starting--;
      }
    }
    final deadline = DateTime.now().add(
      tool == 'sftp_upload_finish'
          ? const Duration(minutes: 10)
          : const Duration(seconds: 30),
    );
    var valid = true;
    void check() {
      authorize();
      if (!valid || DateTime.now().isAfter(deadline)) {
        throw StateError('文件操作超时，可能部分完成；不会自动重试');
      }
    }

    SftpClient? client;
    SftpFile? file;
    try {
      client = await ssh.client.sftp(authorize: check);
      check();
      if (tool == 'sftp_batch') {
        final operations = batchOperations(args);
        var completed = 0;
        for (final (index, operation) in operations.indexed) {
          check();
          try {
            final path = remotePath(operation, 'path');
            if (operation['operation'] == 'rename') {
              await client.renameNoReplace(
                path,
                remotePath(operation, 'destination'),
              );
            } else if (operation['directory'] == true) {
              await client.rmdir(path);
            } else {
              await client.remove(path);
            }
            check();
            completed++;
          } catch (_) {
            check();
            return {
              'completedCount': completed,
              'failedIndex': index,
              'outcome': '该项失败或结果未知，后续未发送；不自动重试',
              'untrusted': true,
            };
          }
        }
        return {'completedCount': completed, 'completed': true};
      }
      if (tool == 'sftp_upload_begin') {
        if (_uploads.length >= 4) throw StateError('最多保留4个上传，请先完成或取消');
        final path = remotePath(args, 'path');
        final size = args['size'];
        final digest = args['sha256'];
        if (size is! int ||
            size < 0 ||
            size > 64 * 1024 * 1024 ||
            digest is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
          throw const FormatException('需要0–64MiB长度及小写SHA-256');
        }
        final id = Host.newId();
        final slash = path.lastIndexOf(47);
        final temporary = Uint8List.fromList([
          ...path.take(slash < 0 ? 0 : slash + 1),
          ...utf8.encode('.salp-mcp-$id.part'),
        ]);
        file = await client.open(
          temporary,
          mode:
              SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.exclusive,
        );
        await file.close();
        file = null;
        check();
        _uploads[id] = _Upload(
          path,
          temporary,
          size,
          digest,
          terminal.input.generation,
          terminal.interactionEpoch,
          terminal.ssh!,
          authority,
        );
        return {'uploadId': id, 'nextOffset': 0, 'maxChunkBytes': 65536};
      }
      if (tool.startsWith('sftp_upload_')) {
        final id = args['uploadId'];
        final upload = _uploads[id];
        if (upload == null) throw StateError('上传不属于此会话');
        if (tool == 'sftp_upload_abort') {
          await client.remove(upload.temporary);
          check();
          _uploads.remove(id);
          return {'aborted': true};
        }
        if (upload.failed ||
            upload.authority != authority ||
            upload.generation != terminal.input.generation ||
            upload.interaction != terminal.interactionEpoch ||
            upload.connection != terminal.ssh ||
            DateTime.now().isAfter(upload.expires)) {
          upload.failed = true;
          throw StateError('上传已失效；请显式取消临时文件后重新开始');
        }
        try {
          if (tool == 'sftp_upload_chunk') {
            final bytes = base64.decode(args['base64'] as String);
            if (args['offset'] != upload.offset ||
                bytes.isEmpty ||
                bytes.length > 65536 ||
                upload.offset + bytes.length > upload.size) {
              throw const FormatException('上传偏移或长度无效，必须按顺序发送最多64KiB');
            }
            file = await client.open(
              upload.temporary,
              mode: SftpFileOpenMode.write,
            );
            final attrs = await file.stat();
            if (attrs.type != SftpFileType.regularFile ||
                attrs.size != upload.offset) {
              throw StateError('远端临时文件已变化');
            }
            await file.writeBytes(
              bytes,
              offset: upload.offset,
              maxPendingRequests: 1,
            );
            await file.close();
            file = null;
            check();
            upload.hash.update(bytes, 0, bytes.length);
            upload.offset += bytes.length;
            return {'nextOffset': upload.offset};
          }
          if (upload.offset != upload.size) throw StateError('上传尚未完整，不会提交');
          final actual = Uint8List(32);
          upload.hash.doFinal(actual, 0);
          final digest = actual
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          if (digest != upload.sha256) throw StateError('SHA-256校验失败，不会提交');
          final attrs = await client.stat(upload.temporary, followLink: false);
          if (attrs.type != SftpFileType.regularFile ||
              attrs.size != upload.size) {
            throw StateError('远端临时文件长度或类型已变化');
          }
          file = await client.open(upload.temporary);
          final remoteHash = SHA256Digest();
          var read = 0;
          await for (final bytes in file.read(
            length: upload.size + 1,
            maxPendingRequests: 2,
          )) {
            check();
            read += bytes.length;
            if (read > upload.size) throw StateError('远端临时文件变长，不会提交');
            remoteHash.update(bytes, 0, bytes.length);
          }
          final remoteDigest = Uint8List(32);
          remoteHash.doFinal(remoteDigest, 0);
          if (read != upload.size ||
              remoteDigest
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join() !=
                  digest) {
            throw StateError('远端文件SHA-256或长度不符，不会提交');
          }
          await file.close();
          file = null;
          check();
          await client.renameNoReplace(upload.temporary, upload.path);
          _uploads.remove(id);
          check();
          return {'written': upload.size, 'sha256': digest, 'replaced': false};
        } catch (_) {
          upload.failed = true;
          rethrow;
        }
      }
      final path = remotePath(args, 'path');
      if (tool == 'sftp_stat') {
        final attrs = await client.stat(path, followLink: false);
        check();
        return {
          'size': attrs.size,
          'mode': attrs.mode?.value,
          'modified': attrs.modifyTime,
          'untrusted': true,
        };
      }
      if (tool == 'sftp_list') {
        final offset = args['offset'] as int? ?? 0;
        if (offset < 0 || offset > 10000) {
          throw const FormatException('目录偏移必须在0–10000');
        }
        var seen = 0;
        final rows = <Map<String, dynamic>>[];
        await for (final batch in client.readdir(path)) {
          check();
          for (final item in batch) {
            if (++seen <= offset) continue;
            if (rows.length == 200) {
              return {
                'entries': rows,
                'nextOffset': offset + rows.length,
                'truncated': true,
                'untrusted': true,
              };
            }
            rows.add({
              'name': utf8.decode(item.filenameBytes, allowMalformed: true),
              'nameBase64': base64.encode(item.filenameBytes),
              'size': item.attr.size,
              'mode': item.attr.mode?.value,
            });
          }
        }
        return {
          'entries': rows,
          'nextOffset': offset + rows.length,
          'truncated': false,
          'untrusted': true,
        };
      }
      if (tool == 'sftp_read') {
        final offset = args['offset'] as int? ?? 0;
        final length = args['length'] as int? ?? 32768;
        if (offset < 0 ||
            offset > 0x1fffffffffffff ||
            length < 1 ||
            length > 65536) {
          throw const FormatException('读取范围无效，单次最多64KiB');
        }
        file = await client.open(path);
        final attrs = await file.stat();
        if (attrs.type != SftpFileType.regularFile) throw StateError('只读取普通文件');
        final data = await file.readBytes(offset: offset, length: length);
        check();
        return {
          'base64': base64.encode(data),
          'nextOffset': offset + data.length,
          'size': attrs.size,
          'untrusted': true,
        };
      }
      if (tool == 'sftp_write') {
        final bytes = base64.decode(args['base64'] as String);
        if (bytes.length > 65536) throw const FormatException('单次文件写入最多64KiB');
        // A unique sibling is published with standard SFTP no-replace rename.
        // Lock/interruption can leave this .part file; never retry automatically.
        final slash = path.lastIndexOf(47);
        final temporary = Uint8List.fromList([
          ...path.take(slash < 0 ? 0 : slash + 1),
          ...utf8.encode('.salp-mcp-${Host.newId()}.part'),
        ]);
        file = await client.open(
          temporary,
          mode:
              SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.exclusive,
        );
        var published = false;
        try {
          await file.writeBytes(bytes, maxPendingRequests: 1);
          await file.close();
          file = null;
          check();
          await client.renameNoReplace(temporary, path);
          published = true;
          check();
          return {'written': bytes.length, 'replaced': false};
        } finally {
          if (!published) {
            try {
              check();
              await client.remove(temporary);
            } catch (_) {
              /* Keep uncertainty; no automatic retry. */
            }
          }
        }
      }
      if (tool == 'sftp_mkdir') {
        await client.mkdir(path);
      } else if (tool == 'sftp_rename') {
        await client.renameNoReplace(path, remotePath(args, 'destination'));
      } else if (tool == 'sftp_remove') {
        // The kind is part of the approved request. Never recurse or infer a
        // directory deletion from a possibly changed listing.
        if (args['directory'] == true) {
          await client.rmdir(path);
        } else {
          await client.remove(path);
        }
      } else {
        throw StateError('工具不存在');
      }
      check();
      return {'completed': true};
    } finally {
      try {
        await file?.close();
      } catch (_) {
        /* Closing the channel frees handles. */
      }
      valid = false;
      await client?.close();
    }
  }

  Map<String, dynamic> approvalArguments(
    String tool,
    Map<String, dynamic> args,
  ) {
    if (!tool.startsWith('sftp_upload_') || tool == 'sftp_upload_begin') {
      return args;
    }
    final upload = _uploads[args['uploadId']];
    if (upload == null) throw StateError('上传不属于此会话');
    return {
      ...args,
      'targetPathBase64': base64.encode(upload.path),
      'temporaryPathBase64': base64.encode(upload.temporary),
      'expectedSize': upload.size,
      'expectedSha256': upload.sha256,
    };
  }

  static List<Map<String, dynamic>> batchOperations(Map<String, dynamic> args) {
    final raw = args['operations'];
    if (raw is! List || raw.isEmpty || raw.length > 100) {
      throw const FormatException('批量操作必须为1–100项');
    }
    return raw.map((item) {
      if (item is! Map) throw const FormatException('批量条目无效');
      final row = Map<String, dynamic>.from(item);
      final kind = row['operation'];
      if (kind != 'rename' && kind != 'remove') {
        throw const FormatException('仅支持移动或删除');
      }
      final allowed = {
        'operation',
        'path',
        'pathBase64',
        if (kind == 'rename') ...['destination', 'destinationBase64'],
        if (kind == 'remove') 'directory',
      };
      if (row.keys.any((key) => !allowed.contains(key)) ||
          (row.containsKey('directory') && row['directory'] is! bool)) {
        throw const FormatException('批量条目参数无效');
      }
      remotePath(row, 'path');
      if (kind == 'rename') remotePath(row, 'destination');
      return row;
    }).toList();
  }

  static Uint8List remotePath(Map<String, dynamic> args, String key) {
    if ((args[key] == null) == (args['${key}Base64'] == null)) {
      throw FormatException('必须提供$key或${key}Base64之一');
    }
    final bytes = args[key] == null
        ? base64.decode(args['${key}Base64'] as String)
        : Uint8List.fromList(utf8.encode(args[key] as String));
    if (bytes.isEmpty || bytes.length > 4096 || bytes.contains(0)) {
      throw const FormatException('远端路径必须为1–4096字节且不含NUL');
    }
    return bytes;
  }

  void close() {
    for (final command in commands.values) {
      command.close();
    }
    commands.clear();
    _uploads.clear(); // No remote cleanup after revoke/close without authority.
  }
}

class _Upload {
  _Upload(
    this.path,
    this.temporary,
    this.size,
    this.sha256,
    this.generation,
    this.interaction,
    this.connection,
    this.authority,
  );
  final Uint8List path, temporary;
  final int size, generation, interaction, authority;
  final String sha256;
  final SshConnection connection;
  final hash = SHA256Digest();
  final expires = DateTime.now().add(const Duration(minutes: 15));
  int offset = 0;
  bool failed = false;
}

class _Command {
  _Command(this.session) {
    _stdout = session.stdout.listen(
      (bytes) => append(out, bytes),
      onError: (Object _) => failed = true,
      onDone: () {
        stdoutDone = true;
      },
    );
    _stderr = session.stderr.listen(
      (bytes) => append(err, bytes),
      onError: (Object _) => failed = true,
      onDone: () {
        stderrDone = true;
      },
    );
    // Commands run without stdin. Close just our input half, not the process.
    unawaited(
      session.stdin.close().catchError((Object _) {
        failed = true;
      }),
    );
  }
  final SSHSession session;
  final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
  late final StreamSubscription<Uint8List> _stdout, _stderr;
  bool truncated = false,
      failed = false,
      stdoutDone = false,
      stderrDone = false;
  void append(BytesBuilder target, Uint8List bytes) {
    final room = 262144 - out.length - err.length;
    if (bytes.length > room) truncated = true;
    if (room > 0) target.add(Uint8List.fromList(bytes.take(room).toList()));
  }

  Map<String, dynamic> snapshot(int stdoutOffset, int stderrOffset) {
    if ([stdoutOffset, stderrOffset].any((v) => v < 0 || v > 262144)) {
      throw const FormatException('输出偏移无效');
    }
    List<int> slice(BytesBuilder bytes, int offset) {
      final data = bytes.toBytes();
      final begin = offset.clamp(0, data.length),
          end = (offset + 32768).clamp(0, data.length);
      return data.sublist(begin, end);
    }

    final stdout = slice(out, stdoutOffset), stderr = slice(err, stderrOffset);
    return {
      'stdout': base64.encode(stdout),
      'stderr': base64.encode(stderr),
      'nextStdoutOffset': stdoutOffset.clamp(0, out.length) + stdout.length,
      'nextStderrOffset': stderrOffset.clamp(0, err.length) + stderr.length,
      'stdoutBytes': out.length,
      'stderrBytes': err.length,
      'running': !(stdoutDone && stderrDone),
      'exitCode': session.exitCode,
      'truncated': truncated,
      'failed': failed,
      'untrusted': true,
    };
  }

  void close() {
    session.channel.destroy();
    unawaited(_stdout.cancel());
    unawaited(_stderr.cancel());
    out.clear();
    err.clear();
  }
}
