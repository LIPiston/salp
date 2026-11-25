import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../core/repository.dart';

class SyncRestoreDialog extends StatefulWidget {
  const SyncRestoreDialog({super.key, required this.repository});
  final Repository repository;
  @override
  State<SyncRestoreDialog> createState() => _SyncRestoreDialogState();
}

class _SyncRestoreDialogState extends State<SyncRestoreDialog> {
  late final authority = widget.repository.epoch;
  late final current = jsonDecode(
    jsonEncode(widget.repository.syncEntries()),
  ) as Map<String, dynamic>;
  late final backup = jsonDecode(
    jsonEncode(widget.repository.syncBackup),
  ) as Map<String, dynamic>;
  final password = TextEditingController();
  late String version = versions.first;
  List<String> get versions =>
      ['local', 'remote', 'undo'].where((v) => backup[v] is Map).toList();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  Future<void> restore() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.restoreSyncBackup(
        version: version,
        password: password.text,
        authority: authority,
        expectedEntries: current,
        expectedBackup: backup,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is StateError
              ? e.message.toString()
              : e is FormatException
              ? e.message
              : '恢复未完成；当前数据保留，请重试',
        );
      }
    } finally {
      password.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = Map<String, dynamic>.from(backup[version] as Map);
    final keys = {...current.keys, ...selected.keys}.toList()..sort();
    final added = keys.where((k) => !current.containsKey(k)).toList();
    final removed = keys.where((k) => !selected.containsKey(k)).toList();
    final changed = keys
        .where(
          (k) =>
              current.containsKey(k) &&
              selected.containsKey(k) &&
              !const DeepCollectionEquality().equals(current[k], selected[k]),
        )
        .toList();
    final affected = [...added, ...removed, ...changed];
    String label(String key) {
      final value = selected[key] ?? current[key];
      if (value is Map && value['host'] is Map) {
        return '主机：${value['host']['name']}';
      }
      return '片段：${key.substring('snippet:'.length)}';
    }

    return AlertDialog(
      title: const Text('恢复本地备份'),
      content: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * .6,
        child: ListView(
          children: [
            const Text('所选版本将替换本地主机、凭据和片段。恢复前版本会保留，可再次进入这里撤销恢复。下次同步前仍需预览确认。'),
            if (backup['createdAt'] is String)
              Text('备份时间：${backup['createdAt']}'),
            if (backup['endpoint'] is String)
              Text('备份来源：${backup['endpoint']}'),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: version,
              decoration: const InputDecoration(labelText: '选择版本'),
              items: [
                for (final v in versions)
                  DropdownMenuItem(
                    value: v,
                    child: Text(switch (v) {
                      'local' => '同步前的本地版本',
                      'remote' => '同步前的远端版本',
                      _ => '恢复前的版本（撤销恢复）',
                    }),
                  ),
              ],
              onChanged: busy ? null : (v) => setState(() => version = v!),
            ),
            const SizedBox(height: 12),
            Text(
              '新增 ${added.length} · 修改 ${changed.length} · 移除 ${removed.length}',
            ),
            const Text('凭据和片段内容已隐藏。'),
            for (final key in affected.take(100))
              Text(
                '${added.contains(key)
                    ? '+'
                    : removed.contains(key)
                    ? '−'
                    : '~'} ${label(key)}',
              ),
            if (affected.length > 100) Text('另有 ${affected.length - 100} 项变更'),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              enabled: !busy,
              obscureText: true,
              decoration: const InputDecoration(labelText: '当前应用主密码'),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy ? null : restore,
          child: Text(busy ? '恢复中…' : '替换本地记录'),
        ),
      ],
    );
  }
}
