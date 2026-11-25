import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/mcp.dart';
import '../core/repository.dart';
import 'dialogs.dart';
import 'logs_dialog.dart';

Future<bool> mcpApprovalDialog(
  BuildContext context,
  McpApproval approval,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${approval.agent.name} 请求操作'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${approval.host.label} · ${approval.host.username}@${approval.host.endpoint}',
                ),
                const SizedBox(height: 12),
                Text(approval.operation),
                if (approval.sessionId != null)
                  Text('专用会话 ${approval.sessionId}'),
                const SizedBox(height: 12),
                SelectableText(
                  approval.exactDisplay,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                if (approval.bytes != null)
                  Text(
                    '${approval.bytes!.length} 字节；不可见字节与反斜线以 \\xHH 显示。批准只适用于本次精确输入。',
                  ),
                const SizedBox(height: 12),
                const Text('远端命令可能修改数据或使用远端网络与凭据。锁定、人工输入或会话变化后此审批失效。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('仅批准这一次'),
          ),
        ],
      ),
    ) ??
    false;

class McpDialog extends StatefulWidget {
  const McpDialog({super.key, required this.repository, required this.server});
  final Repository repository;
  final McpServer server;
  @override
  State<McpDialog> createState() => _McpDialogState();
}

class _McpDialogState extends State<McpDialog> {
  final name = TextEditingController(), port = TextEditingController(text: '0');
  final address = TextEditingController(text: '127.0.0.1');
  final allowedHosts = TextEditingController();
  final allowedOrigins = TextEditingController();
  final hosts = <String>{};
  McpMode mode = McpMode.approve;
  late final authority = widget.repository.epoch;
  bool busy = false;
  String? message, createdToken;
  @override
  void dispose() {
    name.dispose();
    port.dispose();
    address.dispose();
    allowedHosts.dispose();
    allowedOrigins.dispose();
    super.dispose();
  }

  Future<void> create() async {
    final repo = widget.repository;
    if (hosts.isEmpty || name.text.trim().isEmpty) {
      setState(() => message = '请填写 agent 名称并选择主机范围');
      return;
    }
    if (mode == McpMode.yolo &&
        !await confirmDialog(
          context,
          '允许这些主机免逐次审批？',
          'YOLO 仅作用于所选主机。agent 可发送任意远端命令，可能删除数据或访问远端网络；主机密钥和应用锁定仍生效。',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      repo.checkAuthority(authority);
      final agent = McpAgent.create(
        name.text.trim(),
        hosts.toList(),
        mode: mode,
      );
      await repo.update(
        (draft) => draft.mcpAgents.add(agent.toJson()),
        authority: authority,
      );
      repo.checkAuthority(authority);
      if (mounted) {
        setState(() {
          createdToken = agent.token;
          message = '已创建，只能访问勾选的主机';
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = '创建失败或授权已失效');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> toggle() async {
    setState(() => busy = true);
    try {
      widget.repository.checkAuthority(authority);
      if (widget.server.running) {
        await widget.server.close();
      } else {
        final value = int.tryParse(port.text);
        if (value == null || value < 0 || value > 65535) {
          throw const FormatException('端口无效');
        }
        final ip = InternetAddress.tryParse(address.text.trim());
        if (ip == null) throw const FormatException('请输入有效监听IP');
        final hostList = _entries(allowedHosts.text);
        final originList = _entries(allowedOrigins.text);
        var confirmed = false;
        if (!ip.isLoopback) {
          confirmed = await confirmDialog(
            context,
            '允许非回环明文监听？',
            '监听 ${ip.address}:$value 会让其他设备有机会连接。HTTP会明文传输agent密钥、命令和输出，旁路监听者可能取得远端操作权限。这不适合直接暴露到公网。仅允许以下主机头：${hostList.isEmpty ? ip.address : hostList.join(', ')}。',
          );
          if (!confirmed || !mounted) return;
        }
        widget.repository.checkAuthority(authority);
        await widget.server.start(
          port: value,
          address: ip.address,
          allowedHosts: hostList,
          allowedOrigins: originList,
          confirmedNonLoopback: confirmed,
        );
        try {
          widget.repository.checkAuthority(authority);
        } catch (_) {
          await widget.server.close();
          rethrow;
        }
      }
      if (mounted) setState(() => message = null);
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is FormatException
              ? e.message
              : '服务操作失败，请检查地址、端口与授权状态',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  static List<String> _entries(String text) =>
      text.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('桌面 MCP'),
    content: SizedBox(
      width: 700,
      height: MediaQuery.sizeOf(context).height * .7,
      child: ListView(
        children: [
          const Text(
            '默认监听本机回环地址，需要请求头密钥。非回环监听需另行确认。agent 使用专用终端及独立SSH/SFTP通道，无法操作本地 shell、串口或任意本地文件。服务默认关闭。审计只记录元数据，在本机加密保留7天，总量约20MiB。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: address,
            enabled: !busy && !widget.server.running,
            decoration: const InputDecoration(labelText: '监听 IP'),
          ),
          TextField(
            controller: port,
            enabled: !busy && !widget.server.running,
            decoration: const InputDecoration(labelText: '端口（0 表示系统分配）'),
          ),
          TextField(
            controller: allowedHosts,
            enabled: !busy && !widget.server.running,
            decoration: const InputDecoration(
              labelText: '允许访问的主机名或 IP',
              helperText: '逗号分隔，不含端口。通常留空；监听0.0.0.0或::时必须填写实际访问地址。',
              helperMaxLines: 3,
            ),
          ),
          TextField(
            controller: allowedOrigins,
            enabled: !busy && !widget.server.running,
            decoration: const InputDecoration(
              labelText: '额外允许的浏览器 Origin',
              helperText: '通常留空；填写完整http(s)来源，逗号分隔，不含路径。',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: busy ? null : toggle,
            child: Text(widget.server.running ? '停止 MCP 并关闭代理会话' : '启动 MCP'),
          ),
          if (widget.server.running) SelectableText(widget.server.url),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  LogsDialog(repository: widget.repository, audit: true),
            ),
            child: const Text('查看本地审计'),
          ),
          const Divider(),
          for (final record in widget.repository.mcpAgents)
            ListTile(
              title: Text(record['name'] as String),
              subtitle: Text(
                '${record['mode']} · ${(record['hosts'] as List).length} 台主机',
              ),
              trailing: IconButton(
                tooltip: '撤销 agent',
                icon: const Icon(Icons.delete_outline),
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          widget.repository.checkAuthority(authority);
                          await widget.server.revoke(record['id'] as String);
                          if (mounted) setState(() {});
                        } catch (_) {
                          if (mounted) setState(() => message = '撤销未完成，请重试');
                        }
                      },
              ),
            ),
          TextField(
            controller: name,
            enabled: !busy,
            decoration: const InputDecoration(labelText: '新 agent 名称'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<McpMode>(
            initialValue: mode,
            decoration: const InputDecoration(labelText: '审批模式'),
            items: const [
              DropdownMenuItem(value: McpMode.approve, child: Text('每次操作审批')),
              DropdownMenuItem(
                value: McpMode.smart,
                child: Text('智能：读取免审批，输入仍审批'),
              ),
              DropdownMenuItem(
                value: McpMode.yolo,
                child: Text('YOLO：所选主机免逐次审批'),
              ),
            ],
            onChanged: busy ? null : (v) => setState(() => mode = v!),
          ),
          const Text('允许访问的主机（创建后扩大范围需要新建授权）'),
          for (final host in widget.repository.hosts.where(
            (h) => h.protocol.name == 'ssh' || h.protocol.name == 'mosh',
          ))
            CheckboxListTile(
              title: Text(host.label),
              subtitle: Text('${host.username}@${host.endpoint}'),
              value: hosts.contains(host.id),
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      if (v == true) {
                        hosts.add(host.id);
                      } else {
                        hosts.remove(host.id);
                      }
                    }),
            ),
          OutlinedButton(
            onPressed: busy ? null : create,
            child: const Text('创建 agent 与随机密钥'),
          ),
          if (createdToken != null) ...[
            const Text('请保存此密钥，以 Authorization 请求头使用。此处只显示本次创建的密钥。'),
            SelectableText('Authorization: Bearer $createdToken'),
            TextButton(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: createdToken!)),
              child: const Text('复制密钥'),
            ),
          ],
          if (message != null) Text(message!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
