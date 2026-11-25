import 'dart:convert';
import 'dart:io';

import '../core/platform_files.dart';

import 'package:material_ui/material_ui.dart';

import '../core/host.dart';
import '../core/host_import.dart';
import '../core/repository.dart';
import '../core/bounded_read.dart';

class ImportDialog extends StatefulWidget {
  const ImportDialog({super.key, required this.repository});
  final Repository repository;
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  String format = 'OpenSSH';
  ImportPreview? preview;
  String? error;
  bool busy = false;
  Directory? includeRoot;
  late final authority = widget.repository.epoch;

  Future<void> chooseScope() async {
    final uri = await PlatformFiles.pickDirectory();
    if (uri == null || !mounted) return;
    try {
      widget.repository.checkAuthority(authority);
      if (uri.scheme != 'file') {
        throw const FormatException('Include目前仅支持本地文件目录');
      }
      setState(() {
        includeRoot = Directory.fromUri(uri);
        preview = null;
        error = null;
      });
    } catch (_) {
      if (mounted) setState(() => error = '选择目录失败或授权已失效');
    }
  }

  Future<void> pick() async {
    final epoch = authority;
    final selectedFormat = format, scope = includeRoot;
    setState(() => busy = true);
    try {
      widget.repository.checkAuthority(epoch);
      final file = await PlatformFiles.pickFile();
      if (file == null || !mounted) return;
      void check() {
        if (!mounted) throw StateError('窗口已关闭');
        widget.repository.checkAuthority(epoch);
      }

      ImportPreview result;
      if (selectedFormat == 'OpenSSH' && scope != null) {
        if (file.path == null) throw const FormatException('Include仅支持本地文件');
        result = await parseOpenSshFile(File(file.path!), scope, check);
      } else {
        final bytes = await readBounded(
          file.readAsByteStream(),
          maxBytes: 4 * 1024 * 1024,
          authorize: check,
        );
        final text = utf8.decode(bytes);
        result = selectedFormat == 'OpenSSH'
            ? parseOpenSsh(text)
            : parseHostJson(text, selectedFormat);
      }
      check();
      if (mounted) {
        setState(() {
          preview = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          preview = null;
          error = e is FormatException ? e.message : '读取或解析失败，未修改现有配置';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> commit() async {
    final repo = widget.repository;
    final result = preview;
    if (result == null) return;
    final epoch = authority;
    setState(() => busy = true);
    try {
      repo.checkAuthority(epoch);
      await repo.update((draft) {
        for (final h in result.hosts) {
          final conflict = draft.hosts.any((old) => old.name == h.name);
          draft.hosts.add(
            Host(
              id: h.id,
              name: conflict ? '${h.label}（导入）' : h.name,
              address: h.address,
              username: h.username,
              port: h.port,
              group: h.group,
              protocol: h.protocol,
              jumpIds: h.jumpIds,
            ),
          );
        }
      }, authority: epoch);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => error = '导入失败，现有配置已保留');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导入主机配置'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: format,
              items: [
                'OpenSSH',
                'WindTerm',
                'NyaTerm',
              ].map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
              onChanged: busy
                  ? null
                  : (f) => setState(() {
                      format = f!;
                      preview = null;
                    }),
            ),
            const SizedBox(height: 12),
            if (format == 'OpenSSH' && !Platform.isAndroid) ...[
              OutlinedButton(
                onPressed: busy ? null : chooseScope,
                child: const Text('选择 Include 允许目录（可选）'),
              ),
              if (includeRoot != null) Text('允许目录：${includeRoot!.path}'),
              const Text(
                '只展开文件顶部Include；相对路径及~/以所选目录为根，常规用户配置选择.ssh目录。条件Include、越界或循环会停止预览。',
              ),
            ],
            OutlinedButton.icon(
              onPressed: busy ? null : pick,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('选择配置文件'),
            ),
            const Text('仅导入预览中列出的主机字段。密码和私钥不会自动读取；同名主机保留双方。'),
            if (format != 'OpenSSH')
              const Text('JSON 导出：仅识别已列明字段，未知字段会报告。加密导出请先在来源应用解锁。'),
            if (preview != null) ...[
              const SizedBox(height: 16),
              Text('${preview!.hosts.length} 台主机可以导入'),
              for (final host in preview!.hosts)
                ListTile(
                  dense: true,
                  title: Text(host.label),
                  subtitle: Text(
                    '${host.username}@${host.address}:${host.port} · 跳板 ${host.jumpIds.length}',
                  ),
                ),
              if (preview!.warnings.isNotEmpty)
                ExpansionTile(
                  title: Text('${preview!.warnings.length} 项未导入或需确认'),
                  initiallyExpanded: true,
                  children: preview!.warnings
                      .map((w) => ListTile(dense: true, title: Text(w)))
                      .toList(),
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
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy || preview?.hosts.isNotEmpty != true ? null : commit,
        child: Text(busy ? '导入中…' : '导入预览中的主机'),
      ),
    ],
  );
}
