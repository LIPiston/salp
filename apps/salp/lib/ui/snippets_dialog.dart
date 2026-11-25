import 'package:material_ui/material_ui.dart';

import '../core/connection.dart';
import '../core/repository.dart';

class SnippetsDialog extends StatefulWidget {
  const SnippetsDialog({
    super.key,
    required this.repository,
    required this.session,
  });
  final Repository repository;
  final TerminalSession session;
  @override
  State<SnippetsDialog> createState() => _SnippetsDialogState();
}

class _SnippetsDialogState extends State<SnippetsDialog> {
  final name = TextEditingController(), body = TextEditingController();
  late final authority = widget.repository.epoch;
  late final generation = widget.session.input.generation;
  String query = '', message = '';
  String? selectedGroup;
  String groupOf(String name) {
    final separator = name.indexOf('/');
    return separator < 0 ? '' : name.substring(0, separator).trim();
  }

  bool busy = false;
  void check() {
    widget.repository.checkAuthority(authority);
    if (widget.session.closed ||
        widget.session.input.generation != generation) {
      throw StateError('会话已变更');
    }
  }

  @override
  void dispose() {
    name.dispose();
    body.dispose();
    super.dispose();
  }

  Future<void> save({bool remove = false}) async {
    setState(() => busy = true);
    final repo = widget.repository;
    final key = name.text.trim();
    final content = body.text;
    try {
      check();
      if (key.isEmpty || body.text.length > 65536) {
        throw const FormatException('请输入名称；片段不能超过 64 KiB');
      }
      await repo.update((draft) {
        if (remove) {
          draft.snippets.remove(key);
        } else {
          draft.snippets[key] = content;
        }
      }, authority: authority);
      if (mounted) setState(() => message = remove ? '已删除' : '已保存');
    } catch (_) {
      if (mounted) setState(() => message = '操作未完成，请检查内容或重新打开片段');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void insert() {
    try {
      check();
      if (!widget.session.connected) throw StateError('尚未连接');
      widget.session.terminal.paste(body.text);
      Navigator.pop(context);
    } catch (_) {
      setState(() => message = '会话不可用，请重新连接后打开片段');
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries =
        widget.repository.snippets.entries
            .where(
              (e) =>
                  e.key.toLowerCase().contains(query.toLowerCase()) &&
                  (selectedGroup == null || groupOf(e.key) == selectedGroup),
            )
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    final groups = widget.repository.snippets.keys.map(groupOf).toSet().toList()
      ..sort();
    return AlertDialog(
      title: const Text('命令片段'),
      content: SizedBox(
        width: 680,
        height: MediaQuery.sizeOf(context).height * .6,
        child: ListView(
          children: [
            TextField(
              onChanged: (v) => setState(() => query = v),
              decoration: const InputDecoration(labelText: '搜索分组或名称'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: selectedGroup == null,
                  onSelected: (_) => setState(() => selectedGroup = null),
                ),
                for (final group in groups)
                  ChoiceChip(
                    label: Text(group.isEmpty ? '未分组' : group),
                    selected: selectedGroup == group,
                    onSelected: (_) => setState(() => selectedGroup = group),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in entries)
                  ActionChip(
                    label: Text(entry.key),
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            name.text = entry.key;
                            body.text = entry.value;
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: '分组 / 名称',
                hintText: '维护 / 查看磁盘',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: body,
              enabled: !busy,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(labelText: '发送前预览并编辑内容'),
            ),
            const Text('粘贴会发送当前可见内容；片段中如含换行，远端可能立即执行。不会自动追加回车。'),
            if (message.isNotEmpty) Text(message),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: busy ? null : () => save(remove: true),
          child: const Text('删除'),
        ),
        OutlinedButton(
          onPressed: busy ? null : save,
          child: const Text('保存片段'),
        ),
        FilledButton(
          onPressed: busy || !widget.session.connected ? null : insert,
          child: const Text('粘贴到当前会话'),
        ),
      ],
    );
  }
}
