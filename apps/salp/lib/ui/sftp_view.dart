import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import '../core/platform_files.dart';
import 'package:material_ui/material_ui.dart';

import '../core/sftp_session.dart';
import 'dialogs.dart';

class SftpView extends StatefulWidget {
  const SftpView({super.key, required this.session});
  final SftpSession session;
  @override
  State<SftpView> createState() => _SftpViewState();
}

class _SftpViewState extends State<SftpView> {
  final selected = <SftpName>{};
  SftpSession get session => widget.session;
  Future<void> act(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作失败，请检查权限、文件名或连接状态')));
      }
    }
  }

  Future<ConflictChoice> conflict(String name) async =>
      await showDialog<ConflictChoice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('目标文件已存在'),
          content: Text('$name\n现有文件将被保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, ConflictChoice.skip),
              child: const Text('跳过'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, ConflictChoice.keepBoth),
              child: const Text('保留双方'),
            ),
          ],
        ),
      ) ??
      ConflictChoice.skip;
  Future<void> download(List<SftpName> entries) async {
    final check = session.captureAction();
    if (Platform.isAndroid) {
      final directory = await PlatformFiles.chooseAndroidDirectory();
      if (directory == null || !mounted) return;
      check();
      for (final entry in entries.where((e) => !e.attr.isDirectory)) {
        session.downloadAndroid(entry, directory, conflict);
      }
      return;
    }
    final destination = await PlatformFiles.pickDirectory();
    final directory = destination?.scheme == 'file'
        ? destination!.toFilePath()
        : null;
    if (directory == null || !mounted) return;
    check();
    for (final entry in entries.where((e) => !e.attr.isDirectory)) {
      session.download(entry, directory, conflict);
    }
  }

  Future<void> preview(SftpName entry) async {
    final bytes = await session.preview(entry);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(remoteLabel(entry.filenameBytes)),
        content: SizedBox(
          width: 720,
          height: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              utf8.decode(bytes, allowMalformed: true),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              IconButton(
                tooltip: '上级目录',
                onPressed: session.client == null
                    ? null
                    : () => act(session.parent),
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                child: SelectableText(remoteLabel(session.path), maxLines: 1),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: session.client == null
                    ? null
                    : () => act(() => session.list(session.path)),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '新建目录',
                onPressed: session.client == null
                    ? null
                    : () => act(() async {
                        final check = session.captureAction();
                        final name = await textDialog(context, '新建目录');
                        if (name != null && name.isNotEmpty && mounted) {
                          check();
                          await session.mkdir(name);
                        }
                      }),
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
              IconButton(
                tooltip: '上传文件',
                onPressed: session.client == null
                    ? null
                    : () => act(() async {
                        final check = session.captureAction();
                        final files = await PlatformFiles.pickFiles();
                        if (!mounted) return;
                        check();
                        for (final f in files) {
                          session.upload(f, conflict);
                        }
                      }),
                icon: const Icon(Icons.upload),
              ),
              IconButton(
                tooltip: '下载所选',
                onPressed: selected.isEmpty
                    ? null
                    : () => act(() => download(selected.toList())),
                icon: const Icon(Icons.download),
              ),
            ],
          ),
        ),
        if (session.loading) const LinearProgressIndicator(),
        if (session.error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              session.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: session.entries.isEmpty
              ? Center(
                  child: Text(
                    session.client == null ? session.status : '此目录为空',
                  ),
                )
              : ListView.builder(
                  itemCount: session.entries.length,
                  itemBuilder: (context, index) {
                    final entry = session.entries[index];
                    final label = remoteLabel(entry.filenameBytes);
                    return ListTile(
                      dense: true,
                      selected: selected.contains(entry),
                      leading: Checkbox(
                        value: selected.contains(entry),
                        onChanged: (checked) => setState(() {
                          if (checked == true) {
                            selected.add(entry);
                          } else {
                            selected.remove(entry);
                          }
                        }),
                      ),
                      title: Row(
                        children: [
                          Icon(
                            entry.attr.isDirectory
                                ? Icons.folder_outlined
                                : entry.attr.isSymbolicLink
                                ? Icons.link
                                : Icons.insert_drive_file_outlined,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(label, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        entry.attr.isDirectory
                            ? '目录'
                            : entry.attr.isSymbolicLink
                            ? '符号链接'
                            : '${entry.attr.size ?? 0} B',
                      ),
                      onTap: () => act(() async {
                        if (entry.attr.isDirectory &&
                            !entry.attr.isSymbolicLink) {
                          selected.clear();
                          await session.list(
                            remoteChild(session.path, entry.filenameBytes),
                          );
                        } else {
                          await preview(entry);
                        }
                      }),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) => act(() async {
                          final check = session.captureAction();
                          if (action == 'download') await download([entry]);
                          if (action == 'rename' && context.mounted) {
                            final name = await textDialog(
                              context,
                              '重命名',
                              initial: label,
                            );
                            if (name != null && mounted) {
                              check();
                              await session.rename(entry, name);
                            }
                          }
                          if (action == 'delete' &&
                              context.mounted &&
                              await confirmDialog(context, '删除远端条目？', label)) {
                            if (!mounted) return;
                            check();
                            await session.remove(entry);
                          }
                        }),
                        itemBuilder: (_) => [
                          if (!entry.attr.isDirectory)
                            const PopupMenuItem(
                              value: 'download',
                              child: Text('下载'),
                            ),
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('重命名'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        if (session.jobs.isNotEmpty)
          Container(
            height: 170,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: ListView(
              children: [
                for (final job in session.jobs.reversed)
                  ListTile(
                    dense: true,
                    leading: Icon(job.upload ? Icons.upload : Icons.download),
                    title: Text(
                      job.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${switch (job.state) {
                        TransferState.queued => '排队中',
                        TransferState.running => '传输中',
                        TransferState.complete => '完成',
                        TransferState.cancelled => '已取消',
                        TransferState.failed => '失败，可重试',
                      }} · ${job.bytes} / ${job.total ?? '?'} B',
                    ),
                    trailing:
                        job.state == TransferState.running ||
                            job.state == TransferState.queued
                        ? IconButton(
                            tooltip: '取消',
                            onPressed: () => session.cancel(job),
                            icon: const Icon(Icons.close),
                          )
                        : job.state == TransferState.failed ||
                              job.state == TransferState.cancelled
                        ? IconButton(
                            tooltip: '重试',
                            onPressed: () => session.retry(job),
                            icon: const Icon(Icons.refresh),
                          )
                        : const Icon(Icons.check, size: 18),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}
