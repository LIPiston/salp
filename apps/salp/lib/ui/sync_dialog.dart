import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core/master_password.dart';
import '../core/repository.dart';
import '../core/sync.dart';
import '../core/sync_service.dart';
import 'sync_restore_dialog.dart';

class SyncDialog extends StatefulWidget {
  const SyncDialog({super.key, required this.repository});
  final Repository repository;
  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  late final url = TextEditingController(text: widget.repository.webDav['url']);
  late final username = TextEditingController(
    text: widget.repository.webDav['username'],
  );
  late final credential = TextEditingController(
    text: widget.repository.webDav['password'],
  );
  final master = TextEditingController();
  final remoteMaster = TextEditingController();
  WebDavClient? client;
  SyncService? service;
  PreparedSync? prepared;
  final choices = <String, SyncChoice>{};
  bool busy = false, reveal = false;
  String? message;

  @override
  void dispose() {
    prepared?.forget();
    client?.close();
    for (final controller in [
      url,
      username,
      credential,
      master,
      remoteMaster,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> prepare() async {
    final repo = widget.repository;
    final authority = repo.epoch;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      repo.checkAuthority(authority);
      if (repo.masterPassword == null) throw const SyncException('请先在设置中创建主密码');
      final password = master.text;
      if (!await MasterPassword.verify(password, repo.masterPassword!)) {
        throw const SyncException('主密码不正确');
      }
      repo.checkAuthority(authority);
      client?.close();
      client = WebDavClient(
        Uri.parse(url.text.trim()),
        username.text,
        credential.text,
      );
      service = SyncService(repo, client!);
      final settings = {
        'url': url.text.trim(),
        'username': username.text,
        'password': credential.text,
      };
      await repo.update(
        (draft) => draft.webDav = settings,
        authority: authority,
      );
      repo.checkAuthority(authority);
      final next = await service!.prepare(
        remoteMaster.text.isEmpty ? password : remoteMaster.text,
        localPassword: password,
      );
      if (!mounted) {
        next.forget();
        return;
      }
      repo.checkAuthority(authority);
      setState(() {
        prepared = next;
        choices.clear();
        master.clear();
        remoteMaster.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is SyncException || e is FormatException
              ? e.toString()
              : '无法完成同步预览；本地配置保留，请检查连接和授权状态',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> commit() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await service!.commit(prepared!, choices);
      if (mounted) {
        setState(() {
          prepared = null;
          choices.clear();
          message = '同步完成；双方同步前版本已保存在本地加密备份中';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is SyncException
              ? e.toString()
              : '同步未完成；本地数据与双方备份保留。请重新预览核对远端状态',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restoreBackup() async {
    prepared?.forget();
    setState(() {
      prepared = null;
      choices.clear();
    });
    final restored = await showDialog<bool>(
      context: context,
      builder: (_) => SyncRestoreDialog(repository: widget.repository),
    );
    if (mounted && restored == true) {
      setState(() => message = '已恢复本地记录，恢复前版本可撤销；远端尚未修改');
    }
  }

  String describe(Object? value) {
    if (value == null) return '删除此条目';
    if (reveal) return const JsonEncoder.withIndent('  ').convert(value);
    if (value is Map && value['host'] is Map) {
      final h = value['host'] as Map;
      return '${h['name']}\n${h['username']}@${h['address']}:${h['port']}\n分组：${h['group']}\n跳板：${h['jumps']}\n凭据已隐藏';
    }
    return '片段内容已隐藏；显示详细内容后可比较';
  }

  @override
  Widget build(BuildContext context) {
    final draft = prepared;
    return AlertDialog(
      title: const Text('WebDAV 加密同步'),
      content: SizedBox(
        width: 760,
        height: MediaQuery.sizeOf(context).height * .65,
        child: draft == null
            ? ListView(
                children: [
                  const Text(
                    '同步主机、分组、密码、私钥和片段。服务器只能看到加密文件的大小和修改时间。主机密钥信任需要在每台设备上单独确认。',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: url,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: 'HTTPS 文件地址',
                      hintText: 'https://example.com/dav/salp.vault',
                    ),
                  ),
                  const Text('请填写现有目录中的文件地址；首次同步会创建这个文件。'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: username,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: 'WebDAV 用户名'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: credential,
                    enabled: !busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'WebDAV 密码或应用密码',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: master,
                    enabled: !busy,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '应用主密码'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: remoteMaster,
                    enabled: !busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '远端新主密码（通常留空）',
                    ),
                  ),
                  const Text('其他设备更改主密码后，在此输入新密码；同步成功后本机也会改用新密码。'),
                  const Text('WebDAV 登录信息仅保存在本机加密保险库。应用主密码不会保存或发送给服务器。'),
                  if (message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(message!),
                    ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${draft.local.length} 项本地记录 · ${draft.remote.length} 项远端记录 · ${draft.merge.conflicts.length} 项冲突',
                  ),
                  const Text('独立修改会自动合并。冲突必须逐项选择，上传前会保存双方加密备份。'),
                  SwitchListTile(
                    title: const Text('显示详细内容（含密码、私钥）'),
                    value: reveal,
                    onChanged: busy ? null : (v) => setState(() => reveal = v),
                  ),
                  Expanded(
                    child: draft.merge.conflicts.isEmpty
                        ? const Center(child: Text('没有冲突，可以同步'))
                        : ListView.builder(
                            itemCount: draft.merge.conflicts.length,
                            itemBuilder: (context, index) {
                              final conflict = draft.merge.conflicts[index];
                              Widget version(String title, Object? value) =>
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Theme.of(context).dividerColor,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          title,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall,
                                        ),
                                        const SizedBox(height: 8),
                                        SelectableText(describe(value)),
                                      ],
                                    ),
                                  );
                              final left = version('本地版本', conflict.local),
                                  right = version('远端版本', conflict.remote);
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 20),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(conflict.key),
                                    const SizedBox(height: 8),
                                    LayoutBuilder(
                                      builder: (context, c) => c.maxWidth < 520
                                          ? Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                left,
                                                const SizedBox(height: 8),
                                                right,
                                              ],
                                            )
                                          : Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(child: left),
                                                const SizedBox(width: 12),
                                                Expanded(child: right),
                                              ],
                                            ),
                                    ),
                                    DropdownButton<SyncChoice>(
                                      value: choices[conflict.key],
                                      hint: const Text('选择保留版本'),
                                      items: const [
                                        DropdownMenuItem(
                                          value: SyncChoice.local,
                                          child: Text('保留本地'),
                                        ),
                                        DropdownMenuItem(
                                          value: SyncChoice.remote,
                                          child: Text('保留远端'),
                                        ),
                                      ],
                                      onChanged: busy
                                          ? null
                                          : (v) => setState(
                                              () => choices[conflict.key] = v!,
                                            ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  if (message != null) Text(message!),
                ],
              ),
      ),
      actions: [
        if ([
          'local',
          'remote',
          'undo',
        ].any((v) => widget.repository.syncBackup[v] is Map))
          TextButton(
            onPressed: busy ? null : restoreBackup,
            child: const Text('恢复同步备份'),
          ),
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (draft != null)
          TextButton(
            onPressed: busy
                ? null
                : () => setState(() {
                    draft.forget();
                    prepared = null;
                    choices.clear();
                    message = null;
                  }),
            child: const Text('重新预览'),
          ),
        FilledButton(
          onPressed: busy
              ? null
              : draft == null
              ? prepare
              : draft.consumed || choices.length != draft.merge.conflicts.length
              ? null
              : commit,
          child: Text(
            busy
                ? '处理中…'
                : draft == null
                ? '保存连接并预览'
                : '同步已确认的版本',
          ),
        ),
      ],
    );
  }
}
