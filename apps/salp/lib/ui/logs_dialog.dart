import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/repository.dart';
import '../core/session_log.dart';
import 'dialogs.dart';

class LogsDialog extends StatefulWidget {
  const LogsDialog({super.key, required this.repository, this.audit = false});
  final Repository repository;
  final bool audit;
  @override
  State<LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<LogsDialog> {
  late final authority = widget.repository.epoch;
  List<File> files = [];
  String? content, error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final dir = Directory(
        '${widget.repository.directory.path}/${widget.audit ? 'mcp-audit' : 'logs'}',
      );
      await SessionLog.prune(dir);
      final list = await dir.exists()
          ? await dir
                .list()
                .where((f) => f is File && f.path.endsWith('.salp-log'))
                .cast<File>()
                .toList()
          : <File>[];
      list.sort((a, b) => b.path.compareTo(a.path));
      if (mounted) setState(() => files = list);
    } catch (_) {
      if (mounted) setState(() => error = '读取日志列表失败');
    }
  }

  Future<void> open(File file) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      widget.repository.checkAuthority(authority);
      final rows = await SessionLog.read(file, widget.repository.key);
      widget.repository.checkAuthority(authority);
      if (mounted) {
        setState(
          () => content = rows.map((r) => '[${r['at']}] ${r['text']}').join(),
        );
      }
    } catch (_) {
      if (mounted) setState(() => error = '日志无法读取、尚未完成写入或授权已过期');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.audit ? '本地MCP审计' : '本地加密日志'),
    content: SizedBox(
      width: 820,
      height: MediaQuery.sizeOf(context).height * .65,
      child: content != null
          ? SingleChildScrollView(
              child: SelectableText(
                content!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            )
          : Column(
              children: [
                Text(
                  widget.audit
                      ? '只含调用元数据，不含命令、文件路径、输出或密钥；本机加密，保留7天。started缺少结果表示操作结果未知。'
                      : '仅显示主动开启记录的会话。日志含原始输出，可能含机密；只保存在本机，7 天后自动清理。',
                ),
                if (error != null) Text(error!),
                if (busy) const LinearProgressIndicator(),
                Expanded(
                  child: files.isEmpty
                      ? const Center(child: Text('没有本地日志'))
                      : ListView.builder(
                          itemCount: files.length,
                          itemBuilder: (context, index) {
                            final file = files[index];
                            return ListTile(
                              title: Text(file.uri.pathSegments.last),
                              onTap: busy ? null : () => open(file),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除日志',
                                onPressed: busy
                                    ? null
                                    : () async {
                                        if (!await confirmDialog(
                                          context,
                                          '删除这份日志？',
                                          '该操作仅删除所选本地日志。',
                                        )) {
                                          return;
                                        }
                                        try {
                                          widget.repository.checkAuthority(
                                            authority,
                                          );
                                          await file.delete();
                                          await load();
                                        } catch (_) {
                                          if (mounted) {
                                            setState(() => error = '删除失败');
                                          }
                                        }
                                      },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    ),
    actions: [
      if (content != null)
        TextButton(
          onPressed: () => setState(() => content = null),
          child: const Text('返回列表'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
