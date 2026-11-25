import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'connection.dart';
import 'host.dart';
import 'repository.dart';
import 'vault_cipher.dart';
import 'mcp_operations.dart';
import 'session_log.dart';

enum McpMode { approve, smart, yolo }

class McpAgent {
  McpAgent(this.id, this.name, this.token, this.hostIds, this.mode);
  factory McpAgent.create(
    String name,
    List<String> hosts, {
    McpMode mode = McpMode.approve,
  }) => McpAgent(
    Host.newId(),
    name,
    base64Url.encode(VaultCipher.randomBytes(32)),
    [...hosts],
    mode,
  );
  final String id, name, token;
  final List<String> hostIds;
  final McpMode mode;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'token': token,
    'hosts': hostIds,
    'mode': mode.name,
  };
  factory McpAgent.fromJson(Map<String, dynamic> j) => McpAgent(
    j['id'] as String,
    j['name'] as String,
    j['token'] as String,
    List<String>.from(j['hosts'] as List),
    McpMode.values.byName(j['mode'] as String),
  );
}

class McpApproval {
  const McpApproval(
    this.agent,
    this.host,
    this.operation,
    this.sessionId,
    this.bytes,
  );
  final McpAgent agent;
  final Host host;
  final String operation;
  final String? sessionId;
  final Uint8List? bytes;
  String get exactDisplay => bytes == null
      ? operation
      : bytes!
            .map(
              (b) => b >= 32 && b <= 126 && b != 92
                  ? String.fromCharCode(b)
                  : '\\x${b.toRadixString(16).padLeft(2, '0')}',
            )
            .join();
}

class _OwnedSession {
  _OwnedSession(this.owner, this.hostId, this.session);
  final String owner, hostId;
  final TerminalSession session;
  final operations = McpOperations();
  bool busy = false;
  Future<void> close() async {
    operations.close();
    await session.close();
  }
}

class _AuditContext {
  String approver = 'none';
}

class _AuditRun {
  _AuditRun(this.log);
  final SessionLog log;
  bool failed = false;

  bool append(Map<String, dynamic> row) {
    if (failed) return false;
    try {
      if (!log.file.existsSync() || !log.append(jsonEncode(row), flush: true)) {
        failed = true;
      }
    } catch (_) {
      failed = true;
    }
    return !failed;
  }

  Future<void> close() async {
    failed = true;
    await log.close();
  }
}

class McpServer extends ChangeNotifier {
  McpServer(
    this.repository, {
    required this.approve,
    required this.openSession,
  });
  final Repository repository;
  final Future<bool> Function(McpApproval) approve;
  final Future<TerminalSession> Function(Host, String) openSession;
  HttpServer? _server;
  _AuditRun? _audit;
  bool _starting = false;
  Future<void>? _closing;
  final _sessions = <String, _OwnedSession>{};
  final _revoked = <String>{};
  int _inflight = 0, _opening = 0;
  int _epoch = 0;
  String _url = '';
  Set<String> _allowedAuthorities = {}, _allowedOrigins = {};
  String get url => running ? _url : '';
  bool get running => _server != null;

  Future<void> start({
    int port = 0,
    String address = '127.0.0.1',
    List<String> allowedHosts = const [],
    List<String> allowedOrigins = const [],
    bool confirmedNonLoopback = false,
  }) async {
    if (Platform.isAndroid) throw UnsupportedError('Android 不提供 MCP');
    if (_server != null || _starting || _closing != null) {
      throw StateError('MCP 已启动或正在切换状态');
    }
    final bind = InternetAddress.tryParse(address);
    if (bind == null || port < 0 || port > 65535) {
      throw const FormatException('请输入有效监听IP与端口');
    }
    if (!bind.isLoopback && !confirmedNonLoopback) {
      throw StateError('非回环监听需要确认明文传输风险');
    }
    final hosts = allowedHosts.isEmpty ? [bind.address] : [...allowedHosts];
    if (hosts.length > 16 || hosts.any((h) => !_validHost(h))) {
      throw const FormatException('允许的主机必须为明确IP或域名，不含端口、通配符或路径');
    }
    if (allowedOrigins.length > 16 ||
        allowedOrigins.any((o) => !_validOrigin(o))) {
      throw const FormatException('允许的Origin必须为完整http(s)来源，不含路径或通配符');
    }
    final epoch = ++_epoch, authority = repository.epoch;
    repository.checkAuthority(authority);
    _starting = true;
    _AuditRun? audit;
    HttpServer? listener;
    void check() {
      repository.checkAuthority(authority);
      if (_epoch != epoch) throw StateError('MCP 启动已取消');
    }

    try {
      final directory = Directory('${repository.directory.path}/mcp-audit');
      await directory.create(recursive: true);
      check();
      await SessionLog.prune(directory);
      final files = await directory
          .list(followLinks: false)
          .where((e) => e is File && e.path.endsWith('.salp-log'))
          .cast<File>()
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      var total = 0;
      for (final file in files) {
        total += await file.length();
      }
      while (total > 19 * 1024 * 1024 && files.isNotEmpty) {
        check();
        final file = files.removeAt(0);
        final size = await file.length();
        await file.delete();
        total -= size;
      }
      check();
      audit = _AuditRun(
        await SessionLog.start(
          directory,
          repository.key,
          maxBytes: 1024 * 1024,
        ),
      );
      check();
      listener = await HttpServer.bind(bind, port);
      check();
      _allowedAuthorities = {
        for (final h in hosts) _authority(h, listener.port),
      };
      _allowedOrigins = {
        for (final h in _allowedAuthorities) 'http://$h',
        ...allowedOrigins,
      };
      _url = 'http://${_allowedAuthorities.first}/mcp';
      _audit = audit;
      _server = listener;
      listener.listen((request) => _handle(request, epoch));
    } catch (_) {
      await listener?.close(force: true);
      await audit?.close();
      rethrow;
    } finally {
      _starting = false;
    }
    notifyListeners();
  }

  static String _authority(String host, int port) =>
      '${host.contains(':') ? '[$host]' : host}:$port';

  static bool _validHost(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) {
      return ip.rawAddress.any((b) => b != 0) &&
          !ip.isMulticast &&
          host == ip.address;
    }
    if (host.length > 253 || host != host.toLowerCase()) return false;
    return host
        .split('.')
        .every(
          (label) =>
              label.isNotEmpty &&
              label.length <= 63 &&
              RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
        );
  }

  static bool _validOrigin(String origin) {
    final uri = Uri.tryParse(origin);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.userInfo.isEmpty &&
        uri.path.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        _validHost(uri.host) &&
        uri.port > 0 &&
        uri.port <= 65535 &&
        origin == uri.origin;
  }

  bool _equal(String a, String b) {
    final x = utf8.encode(a), y = utf8.encode(b);
    var difference = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      difference |= x[i] ^ y[i];
    }
    return difference == 0;
  }

  McpAgent? _authenticate(String authorization) {
    for (final json in repository.mcpAgents) {
      final agent = McpAgent.fromJson(json);
      if (!_revoked.contains(agent.id) &&
          agent.token.length >= 16 &&
          _equal(authorization, 'Bearer ${agent.token}')) {
        return agent;
      }
    }
    return null;
  }

  void _check(McpAgent agent, int authority, int serverEpoch) {
    if (repository.locked || repository.epoch != authority) {
      throw StateError('需要解锁 salp');
    }
    if (!running || serverEpoch != _epoch) throw StateError('MCP 服务已停止');
    if (_authenticate('Bearer ${agent.token}')?.id != agent.id) {
      throw StateError('agent 授权已撤销');
    }
  }

  void _reply(HttpRequest request, int status, Map<String, dynamic> value) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('cache-control', 'no-store');
    request.response.write(jsonEncode(value));
    unawaited(request.response.close().catchError((Object _) {}));
  }

  Future<void> _handle(HttpRequest request, int serverEpoch) async {
    if (!running || serverEpoch != _epoch) {
      _reply(request, 503, {'error': 'MCP 服务已停止'});
      return;
    }
    final agent = _authenticate(request.headers.value('authorization') ?? '');
    if (agent == null) {
      _reply(request, 401, {'error': '需要有效 MCP 凭据'});
      return;
    }
    final authority = repository.epoch;

    final requestHost = request.headers.value('host');
    final origin = request.headers.value('origin');
    if (!_allowedAuthorities.contains(requestHost) ||
        (origin != null && !_allowedOrigins.contains(origin))) {
      _reply(request, 403, {'error': 'Host/Origin 不被允许'});
      return;
    }
    if (request.method != 'POST' ||
        request.uri.path != '/mcp' ||
        request.uri.hasQuery) {
      _reply(request, 404, {'error': '无此端点'});
      return;
    }
    if (_inflight >= 16) {
      _reply(request, 429, {'error': '请求过多'});
      return;
    }
    _inflight++;
    Object? id;
    try {
      _check(agent, authority, serverEpoch);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in request.timeout(const Duration(seconds: 10))) {
        if (bytes.length + chunk.length > 128 * 1024) {
          throw const FormatException('请求超过 128 KiB 上限');
        }
        bytes.add(chunk);
      }
      final body =
          jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
      id = body['id'];
      if (body['jsonrpc'] != '2.0' ||
          (id != null && id is! String && id is! num)) {
        throw const FormatException('JSON-RPC 格式无效');
      }
      _check(agent, authority, serverEpoch);
      final method = body['method'];
      if (method == 'notifications/initialized') {
        request.response.statusCode = 202;
        await request.response.close();
        return;
      }
      Object result;
      if (method == 'initialize') {
        result = {
          'protocolVersion': '2025-03-26',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'salp', 'version': '0.1.0'},
        };
      } else if (method == 'ping') {
        result = <String, dynamic>{};
      } else if (method == 'tools/list') {
        result = {'tools': _tools};
      } else if (method == 'tools/call') {
        final params = Map<String, dynamic>.from(body['params'] as Map);
        final value = await _auditedCall(
          agent,
          params['name'] as String,
          Map<String, dynamic>.from(params['arguments'] as Map? ?? {}),
          authority,
          serverEpoch,
        );
        _check(agent, authority, serverEpoch);
        result = {
          'content': [
            {'type': 'text', 'text': jsonEncode(value)},
          ],
        };
      } else {
        throw StateError('不支持的 MCP 方法');
      }
      _check(agent, authority, serverEpoch);
      _reply(request, 200, {'jsonrpc': '2.0', 'id': id, 'result': result});
    } catch (e) {
      final message = repository.locked || repository.epoch != authority
          ? '需要解锁 salp'
          : e is StateError
          ? e.message.toString()
          : e is FormatException
          ? e.message
          : 'MCP 操作失败；不会自动重试';
      _reply(request, 200, {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32000, 'message': message},
      });
    } finally {
      _inflight--;
    }
  }

  Future<Object> _auditedCall(
    McpAgent agent,
    String tool,
    Map<String, dynamic> args,
    int authority,
    int serverEpoch,
  ) async {
    _check(agent, authority, serverEpoch);
    final allowedTool = {
      'hosts_list',
      'terminal_open',
      'terminal_read',
      'terminal_write',
      'terminal_close',
      ..._structuredTools,
    }.contains(tool);
    final owned = _sessions[args['sessionId']];
    final target = tool == 'terminal_open' ? args['hostId'] : owned?.hostId;
    final context = _AuditContext();
    final timer = Stopwatch()..start();
    final id = Host.newId();
    Map<String, dynamic> row(String result) => {
      'requestId': id,
      'agentId': agent.id,
      'hostId': target is String && agent.hostIds.contains(target)
          ? target
          : null,
      'operation': allowedTool ? tool : 'unknown',
      'result': result,
      'approver': context.approver,
      'elapsedMs': timer.elapsedMilliseconds,
    };
    // No input, output, remote paths, credentials or caller-supplied names.
    final audit = _audit;
    if (audit?.append(row('started')) != true) {
      throw StateError('MCP审计已达容量或不可写，请重新启动MCP');
    }
    var outcome = 'failed_or_unknown';
    try {
      final result = await _call(
        agent,
        tool,
        args,
        authority,
        serverEpoch,
        context,
      );
      outcome = 'completed';
      return result;
    } finally {
      // Keep the original run even if the service stopped/restarted while
      // awaiting approval. Missing completion leaves the started row unknown.
      audit!.append(row(outcome));
    }
  }

  Future<Object> _call(
    McpAgent agent,
    String tool,
    Map<String, dynamic> args,
    int authority,
    int serverEpoch,
    _AuditContext audit,
  ) async {
    void check() => _check(agent, authority, serverEpoch);
    check();
    if (tool == 'hosts_list') {
      return repository.hosts
          .where((h) => agent.hostIds.contains(h.id))
          .map(
            (h) => {'id': h.id, 'name': h.label, 'protocol': h.protocol.name},
          )
          .take(200)
          .toList();
    }
    final id = args['sessionId'] as String?;
    final owned = id == null ? null : _sessions[id];
    final hostId = tool == 'terminal_open'
        ? args['hostId'] as String?
        : owned?.hostId;
    if (hostId == null ||
        !agent.hostIds.contains(hostId) ||
        (id != null && owned?.owner != agent.id)) {
      throw StateError('目标不在当前 agent 授权范围');
    }
    final host = repository.host(hostId);
    if (host.protocol != Protocol.ssh && host.protocol != Protocol.mosh) {
      throw StateError('MCP 仅支持 SSH/Mosh 专用会话');
    }
    final session = owned?.session;
    final generation = session?.input.generation;
    final interaction = session?.interactionEpoch;
    void checkSession() {
      check();
      if (session != null &&
          (session.closed ||
              session.input.generation != generation ||
              session.interactionEpoch != interaction)) {
        throw StateError('会话上下文已变化，请重新申请操作');
      }
    }

    final structured = _structuredTools.contains(tool);
    Uint8List? payload;
    if (structured) {
      if (host.protocol != Protocol.ssh || owned == null) {
        throw StateError('结构化工具需要SSH专用会话');
      }
      final allowed = <String>{
        'sessionId',
        ...switch (tool) {
          'exec_start' => ['command'],
          'exec_read' => [
            'commandId',
            'offset',
            'stdoutOffset',
            'stderrOffset',
          ],
          'exec_close' => ['commandId'],
          'sftp_batch' => ['operations'],
          'sftp_upload_begin' => ['path', 'pathBase64', 'size', 'sha256'],
          'sftp_upload_chunk' => ['uploadId', 'offset', 'base64'],
          'sftp_upload_finish' || 'sftp_upload_abort' => ['uploadId'],
          _ => [
            'path',
            'pathBase64',
            if (tool == 'sftp_rename') ...['destination', 'destinationBase64'],
            if (tool == 'sftp_write') 'base64',
            if (tool == 'sftp_remove') 'directory',
            if (tool == 'sftp_read' || tool == 'sftp_list') 'offset',
            if (tool == 'sftp_read') 'length',
          ],
        },
      };
      if (args.keys.any((k) => !allowed.contains(k))) {
        throw const FormatException('包含不支持的参数，不允许本地文件路径');
      }
      if (tool == 'sftp_batch') {
        McpOperations.batchOperations(args);
      } else if (tool.startsWith('sftp_') &&
          (!tool.startsWith('sftp_upload_') || tool == 'sftp_upload_begin')) {
        McpOperations.remotePath(args, 'path');
      }
      if (tool == 'sftp_rename') McpOperations.remotePath(args, 'destination');
      final approvalArgs = owned.operations.approvalArguments(tool, args);
      final keys = approvalArgs.keys.toList()..sort();
      payload = Uint8List.fromList(
        utf8.encode(jsonEncode({for (final k in keys) k: approvalArgs[k]})),
      );
    }
    if (tool == 'terminal_write') {
      payload = base64.decode(args['base64'] as String);
      if (payload.isEmpty || payload.length > 65536) {
        throw const FormatException('输入必须为 1–65536 字节');
      }
    }
    if (![
          'terminal_open',
          'terminal_read',
          'terminal_write',
          'terminal_close',
        ].contains(tool) &&
        !structured) {
      throw StateError('工具不存在');
    }
    final needsApproval =
        agent.mode == McpMode.approve ||
        (agent.mode == McpMode.smart &&
            !{
              'terminal_read',
              'exec_read',
              'sftp_stat',
              'sftp_list',
              'sftp_read',
            }.contains(tool));
    if (needsApproval &&
        !await approve(McpApproval(agent, host, tool, id, payload))
            .timeout(const Duration(minutes: 2), onTimeout: () => false)) {
      throw StateError('操作未获批准');
    }
    audit.approver = needsApproval
        ? 'human'
        : agent.mode == McpMode.yolo
        ? 'yolo'
        : 'read_rule';
    checkSession();
    if (structured) {
      if (owned!.busy) throw StateError('此代理会话有操作进行中，请等待结果');
      owned.busy = true;
      try {
        return await owned.operations.call(
          tool,
          args,
          session!,
          authority,
          checkSession,
        );
      } finally {
        owned.busy = false;
      }
    }
    if (tool == 'terminal_open') {
      _sessions.removeWhere((_, value) {
        if (!value.session.closed) return false;
        value.operations.close();
        return true;
      });
      if (_sessions.length + _opening >= 16) throw StateError('代理会话已达 16 个上限');
      _opening++;
      try {
        final opened = await openSession(host, '${agent.name} · ${host.label}');
        try {
          check();
        } catch (_) {
          await opened.close();
          rethrow;
        }
        final sessionId = Host.newId();
        _sessions[sessionId] = _OwnedSession(agent.id, host.id, opened);
        return {
          'sessionId': sessionId,
          'status': opened.status,
          if (opened.error != null) 'error': opened.error,
        };
      } finally {
        _opening--;
      }
    }
    if (tool == 'terminal_read') {
      final output = session!.terminal.buffer.getText();
      final offset = (args['offset'] as int? ?? 0).clamp(0, output.length);
      final end = (offset + 32768).clamp(0, output.length);
      return {
        'text': output.substring(offset, end),
        'nextOffset': end,
        'truncated': end < output.length,
        'status': session.status,
        'untrusted': true,
      };
    }
    if (tool == 'terminal_write') {
      if (!session!.connected) throw StateError('会话尚未连接');
      final inputEpoch = ++session.interactionEpoch;
      await session.input.send(
        payload!,
        generation!,
        authorize: () {
          check();
          if (session.interactionEpoch != inputEpoch) {
            throw StateError('审批上下文已变化');
          }
        },
      );
      check();
      return {'status': '已提交给传输层；远端执行结果需另行读取'};
    }
    await owned!.close();
    _sessions.remove(id);
    return {'closed': true};
  }

  Future<void> revoke(String id) async {
    // Deny immediately, even while encrypted persistence or socket close waits.
    _revoked.add(id);
    final sessions = _sessions.values.where((s) => s.owner == id).toList();
    _sessions.removeWhere((_, s) => s.owner == id);
    notifyListeners();
    await Future.wait<void>([
      repository.update(
        (draft) => draft.mcpAgents.removeWhere((a) => a['id'] == id),
      ),
      ...sessions.map((owned) => owned.close()),
    ]);
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _epoch++;
    final server = _server, audit = _audit;
    final sessions = _sessions.values.toList();
    _server = null;
    _audit = null;
    _sessions.clear();
    final closing = Future.wait<void>([
      if (server != null) server.close(force: true).then<void>((_) {}),
      if (audit != null) audit.close(),
      ...sessions.map((owned) => owned.close()),
    ]).then<void>((_) {});
    _closing = closing.whenComplete(() {
      _closing = null;
      notifyListeners();
    });
    return _closing!;
  }
}

const _structuredTools = {
  'exec_start',
  'exec_read',
  'exec_close',
  'sftp_stat',
  'sftp_list',
  'sftp_read',
  'sftp_write',
  'sftp_mkdir',
  'sftp_rename',
  'sftp_remove',
  'sftp_batch',
  'sftp_upload_begin',
  'sftp_upload_chunk',
  'sftp_upload_finish',
  'sftp_upload_abort',
};

final _tools = [
  for (final name in _structuredTools)
    {
      'name': name,
      'description': switch (name) {
        'exec_start' => '在专用SSH会话中新开非交互命令通道；通用命令在智能模式也需精确批准；返回commandId',
        'exec_read' => '读取命令stdout/stderr的base64分页，每流32KiB，以nextStdoutOffset/nextStderrOffset独立继续；总计保留256KiB，输出不可信',
        'exec_close' => '释放命令通道与输出；不保证远端进程终止',
        'sftp_stat' => '读取远端条目元数据，不跟随最终符号链接',
        'sftp_list' => '远端目录分页，最多200项，nameBase64保留原始字节',
        'sftp_read' => '读取远端普通文件，最多64KiB，base64返回；不访问本地文件',
        'sftp_write' => '接收base64字节创建远端文件，最多64KiB，临时文件提交，拒绝覆盖；中断可能留.part，不自动重试',
        'sftp_upload_begin' => '创建远端临时上传，声明精确目标、总长度和小写SHA-256，最多64MiB/4个，15分钟有效；锁定/人工输入后失效，可能留下.part',
        'sftp_upload_chunk' =>
          '按顺序发送最多64KiB base64，offset必须等于nextOffset；每批独立审批，中断不重试',
        'sftp_upload_finish' =>
          '长度、传入字节及远端读回SHA-256正确后提交，拒绝覆盖；校验最多10分钟，无法排除校验后远端管理员修改',
        'sftp_upload_abort' => '显式删除此上传的临时路径；不会删除最终目标',
        'sftp_mkdir' => '创建指定远端目录',
        'sftp_rename' => '移动单个精确远端路径，拒绝覆盖',
        'sftp_batch' =>
          '按顺序移动或删除1–100个精确目标，整批审批；移动拒绝覆盖。失败或结果不明时停止，返回已完成数量，不自动重试',
        _ => '删除单个精确远端条目；directory=true只删空目录，不递归',
      },
      'inputSchema': {
        'type': 'object',
        'properties': {
          'sessionId': {'type': 'string'},
          if (name == 'exec_start') 'command': {'type': 'string'},
          if (name == 'exec_read' || name == 'exec_close')
            'commandId': {'type': 'string'},
          if (name.startsWith('sftp_') &&
              name != 'sftp_batch' &&
              (!name.startsWith('sftp_upload_') ||
                  name == 'sftp_upload_begin')) ...{
            'path': {'type': 'string'},
            'pathBase64': {'type': 'string'},
          },
          if (name == 'sftp_rename') ...{
            'destination': {'type': 'string'},
            'destinationBase64': {'type': 'string'},
          },
          if (name == 'sftp_write' || name == 'sftp_upload_chunk')
            'base64': {'type': 'string'},
          if (name == 'sftp_upload_begin') ...{
            'size': {'type': 'integer', 'minimum': 0, 'maximum': 67108864},
            'sha256': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
          },
          if (name.startsWith('sftp_upload_') && name != 'sftp_upload_begin')
            'uploadId': {'type': 'string'},
          if (name == 'sftp_batch')
            'operations': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 100,
              'items': {
                'type': 'object',
                'additionalProperties': false,
                'properties': {
                  'operation': {
                    'type': 'string',
                    'enum': ['rename', 'remove'],
                  },
                  'path': {'type': 'string'},
                  'pathBase64': {'type': 'string'},
                  'destination': {'type': 'string'},
                  'destinationBase64': {'type': 'string'},
                  'directory': {'type': 'boolean'},
                },
                'required': ['operation'],
              },
            },
          if (name == 'sftp_remove') 'directory': {'type': 'boolean'},
          if ({
            'exec_read',
            'sftp_read',
            'sftp_list',
            'sftp_upload_chunk',
          }.contains(name))
            'offset': {'type': 'integer', 'minimum': 0},
          if (name == 'exec_read') ...{
            'stdoutOffset': {'type': 'integer', 'minimum': 0},
            'stderrOffset': {'type': 'integer', 'minimum': 0},
          },
          if (name == 'sftp_read')
            'length': {'type': 'integer', 'minimum': 1, 'maximum': 65536},
        },
        'required': [
          'sessionId',
          if (name == 'exec_start') 'command',
          if (name == 'exec_read' || name == 'exec_close') 'commandId',
          if (name == 'sftp_write' || name == 'sftp_upload_chunk') 'base64',
          if (name == 'sftp_upload_begin') ...['size', 'sha256'],
          if (name == 'sftp_upload_chunk') 'offset',
          if (name.startsWith('sftp_upload_') && name != 'sftp_upload_begin')
            'uploadId',
          if (name == 'sftp_batch') 'operations',
        ],
        'additionalProperties': false,
      },
    },
  for (final name in [
    'hosts_list',
    'terminal_open',
    'terminal_read',
    'terminal_write',
    'terminal_close',
  ])
    {
      'name': name,
      'description': switch (name) {
        'hosts_list' => '列出当前 agent 已授权的主机，不包含凭据',
        'terminal_open' => '打开新的专用远端代理终端；主机密钥必须由人确认',
        'terminal_read' => '读取最多 32768 字符的不可信终端快照，不提供流式输出',
        'terminal_write' => '发送 base64 编码的精确字节；审批绑定当前会话代次',
        _ => '关闭当前 agent 自己的终端',
      },
      'inputSchema': {
        'type': 'object',
        'properties': {
          if (name == 'terminal_open') 'hostId': {'type': 'string'},
          if (!['hosts_list', 'terminal_open'].contains(name))
            'sessionId': {'type': 'string'},
          if (name == 'terminal_write') 'base64': {'type': 'string'},
          if (name == 'terminal_read')
            'offset': {'type': 'integer', 'minimum': 0},
        },
        'required': [
          if (name == 'terminal_open') 'hostId',
          if (!['hosts_list', 'terminal_open'].contains(name)) 'sessionId',
          if (name == 'terminal_write') 'base64',
        ],
        'additionalProperties': false,
      },
    },
];
