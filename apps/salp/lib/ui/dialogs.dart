import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import '../core/platform_files.dart';
import 'package:material_ui/material_ui.dart';

import '../core/host.dart';
import '../core/repository.dart';
import '../core/bounded_read.dart';

Future<bool> verifyHostDialog(
  BuildContext context,
  Host host,
  String algorithm,
  String fingerprint,
  String? previous,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(previous == null ? '确认首次连接的主机密钥' : '主机密钥已变更'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${host.label}\n${host.username}@${host.endpoint}'),
              const SizedBox(height: 16),
              Text(
                previous == null
                    ? '请通过可信渠道核对指纹。保存后需要再次点击连接。'
                    : '连接已阻断。请先核实变更原因；保存新密钥后需要重新连接。',
              ),
              const SizedBox(height: 16),
              SelectableText('$algorithm\n$fingerprint'),
              if (previous != null) ...[
                const SizedBox(height: 16),
                const Text('之前保存的密钥'),
                SelectableText(previous),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('信任并保存这把密钥'),
          ),
        ],
      ),
    ) ??
    false;

Future<List<String>?> authDialog(
  BuildContext context,
  SSHUserInfoRequest request,
) async {
  final controllers = request.prompts
      .map((_) => TextEditingController())
      .toList();
  try {
    return await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(request.name.isEmpty ? '服务器认证' : request.name),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (request.instruction.isNotEmpty) Text(request.instruction),
              for (var i = 0; i < controllers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: controllers[i],
                    obscureText: !request.prompts[i].echo,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: request.prompts[i].promptText,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, controllers.map((c) => c.text).toList()),
            child: const Text('继续'),
          ),
        ],
      ),
    );
  } finally {
    for (final c in controllers) {
      c.dispose();
    }
  }
}

Future<String?> textDialog(
  BuildContext context,
  String title, {
  String initial = '',
  bool secret = false,
}) async {
  final controller = TextEditingController(text: initial);
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: secret,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String description,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

class HostEditor extends StatefulWidget {
  const HostEditor({super.key, required this.repository, this.host});
  final Repository repository;
  final Host? host;
  @override
  State<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends State<HostEditor> {
  final name = TextEditingController(),
      address = TextEditingController(),
      port = TextEditingController(text: '22'),
      username = TextEditingController(text: 'root'),
      group = TextEditingController(),
      password = TextEditingController(),
      privateKey = TextEditingController(),
      passphrase = TextEditingController();
  late final int authority;
  Protocol protocol = Protocol.ssh;
  List<String> jumps = [];
  bool saving = false, useAgent = false;
  String? error;
  @override
  void initState() {
    super.initState();
    authority = widget.repository.epoch;
    final host = widget.host;
    if (host != null) {
      protocol = host.protocol;
      name.text = host.name;
      address.text = host.address;
      port.text = '${host.port}';
      username.text = host.username;
      group.text = host.group;
      jumps = [...host.jumpIds];
      final c = widget.repository.credentials[host.id];
      useAgent = c?.useAgent ?? false;
      password.text = c?.password ?? '';
      privateKey.text = c?.privateKey ?? '';
      passphrase.text = c?.passphrase ?? '';
    }
  }

  @override
  void dispose() {
    for (final c in [
      name,
      address,
      port,
      username,
      group,
      password,
      privateKey,
      passphrase,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      widget.repository.checkAuthority(authority);
      final host = Host(
        id: widget.host?.id ?? Host.newId(),
        name: name.text.trim(),
        address: address.text.trim(),
        port: int.tryParse(port.text) ?? 0,
        username: username.text.trim(),
        group: group.text.trim(),
        jumpIds: jumps,
        protocol: protocol,
      );
      await widget.repository.upsert(
        host,
        Credential(
          password: password.text,
          privateKey: privateKey.text,
          passphrase: passphrase.text,
          useAgent: useAgent,
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              error = e is FormatException ? e.message : '保存失败，请检查系统安全存储和磁盘空间',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget field(TextEditingController c, String label, {bool secret = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: secret,
          autocorrect: false,
          decoration: InputDecoration(labelText: label),
        ),
      );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.host == null ? '新建主机' : '编辑主机'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            field(name, '名称'),
            DropdownButtonFormField<Protocol>(
              initialValue: protocol,
              decoration: const InputDecoration(labelText: '协议'),
              items: Protocol.values
                  .map(
                    (p) => DropdownMenuItem(
                      value: p,
                      child: Text(p.name.toUpperCase()),
                    ),
                  )
                  .toList(),
              onChanged: (p) {
                if (p != null) {
                  setState(() {
                    protocol = p;
                    if (p == Protocol.rdp && port.text == '22') {
                      port.text = '3389';
                    }
                    if (p == Protocol.vnc && port.text == '22') {
                      port.text = '5900';
                    }
                    if (p == Protocol.telnet && port.text == '22') {
                      port.text = '23';
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(flex: 3, child: field(address, '地址')),
                const SizedBox(width: 12),
                Expanded(child: field(port, '端口')),
              ],
            ),
            Row(
              children: [
                Expanded(child: field(username, '用户名')),
                const SizedBox(width: 12),
                Expanded(child: field(group, '分组')),
              ],
            ),
            if (!Platform.isAndroid)
              SwitchListTile(
                title: const Text('使用本机 ssh-agent'),
                subtitle: const Text('使用已加载密钥进行本机签名'),
                value: useAgent,
                onChanged: (value) => setState(() => useAgent = value),
              ),
            field(password, '密码', secret: true),
            Row(
              children: [
                Expanded(
                  child: Text(
                    privateKey.text.isEmpty ? '未选择私钥' : '已加载私钥（加密保存）',
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    void check() {
                      if (!mounted) throw StateError('窗口已关闭');
                      widget.repository.checkAuthority(authority);
                    }

                    try {
                      check();
                      final files = await PlatformFiles.pickFiles();
                      check();
                      if (files.isEmpty) return;
                      final bytes = await readBounded(
                        files.first.readAsByteStream(),
                        maxBytes: 1024 * 1024,
                        authorize: check,
                      );
                      setState(() => privateKey.text = utf8.decode(bytes));
                    } catch (_) {
                      if (mounted) {
                        setState(() => error = '私钥读取失败、超过 1 MiB 或授权已失效');
                      }
                    }
                  },
                  child: const Text('选择私钥'),
                ),
                if (privateKey.text.isNotEmpty)
                  IconButton(
                    onPressed: () => setState(() => privateKey.clear()),
                    icon: const Icon(Icons.clear),
                  ),
              ],
            ),
            field(passphrase, '私钥口令', secret: true),
            if (widget.repository.hosts.any(
              (h) => h.id != widget.host?.id,
            )) ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('跳板路径（按添加顺序）'),
              ),
              for (var i = 0; i < jumps.length; i++)
                ListTile(
                  dense: true,
                  title: Text(
                    '${i + 1}. ${widget.repository.host(jumps[i]).label}',
                  ),
                  trailing: IconButton(
                    onPressed: () => setState(() => jumps.removeAt(i)),
                    icon: const Icon(Icons.close),
                  ),
                ),
              DropdownButton<String>(
                isExpanded: true,
                hint: const Text('添加跳板主机'),
                value: null,
                items: widget.repository.hosts
                    .where(
                      (h) => h.id != widget.host?.id && !jumps.contains(h.id),
                    )
                    .map(
                      (h) =>
                          DropdownMenuItem(value: h.id, child: Text(h.label)),
                    )
                    .toList(),
                onChanged: (id) {
                  if (id != null && jumps.length < 8) {
                    setState(() => jumps.add(id));
                  }
                },
              ),
            ],
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? '正在保存…' : '保存主机'),
      ),
    ],
  );
}
