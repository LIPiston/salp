import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../core/host.dart';
import '../core/repository.dart';
import '../core/sync_service.dart';
import '../core/sync.dart';
import '../core/master_password.dart';
import '../core/connection.dart';
import '../core/sftp_session.dart';
import 'dialogs.dart';
import 'sftp_view.dart';
import 'tunnel_dialog.dart';
import 'import_dialog.dart';
import 'sync_dialog.dart';
import 'snippets_dialog.dart';
import 'logs_dialog.dart';
import 'serial_dialog.dart';
import 'mcp_dialog.dart';
import 'split_pane.dart';
import '../core/mcp.dart';
import '../core/platform_lock.dart';
import '../core/android_documents.dart';
import '../core/platform_files.dart';
import '../core/vnc.dart';
import '../core/rdp.dart';
import 'vnc_view.dart';
import 'highlight_dialog.dart';

class _Tab {
  _Tab.terminal(this.terminal) : files = null, desktop = null;
  _Tab.files(this.files) : terminal = null, desktop = null;
  _Tab.desktop(this.desktop) : terminal = null, files = null;
  final VncSession? desktop;
  final TerminalSession? terminal;
  final SftpSession? files;
  String get title =>
      terminal?.title ??
      (files != null
          ? '${files!.host.label} · SFTP'
          : '${desktop!.host.label} · ${desktop!.host.protocol.name.toUpperCase()}');
  Listenable get listenable => terminal ?? files ?? desktop!;
  String get status => terminal?.status ?? files?.status ?? desktop!.status;
  Future<void> close() =>
      terminal?.close() ?? files?.close() ?? desktop!.close();
}

class Workbench extends StatefulWidget {
  const Workbench({super.key, required this.repository});
  final Repository repository;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> with WidgetsBindingObserver {
  bool locked = false, osLocked = false;
  late final McpServer mcp;
  bool _approving = false;
  bool _recoveryReported = false;
  DateTime lastActivity = DateTime.now();
  Timer? idleTimer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PlatformLock.listen((value) {
      if (!mounted) return;
      osLocked = value;
      if (value) {
        lock();
      } else if (repo.masterPassword == null) {
        resumeUnlocked();
      } else {
        setState(() {});
      }
    });
    mcp = McpServer(
      repo,
      approve: (approval) async {
        if (_approving || !mounted || repo.locked) return false;
        _approving = true;
        try {
          return await mcpApprovalDialog(context, approval);
        } finally {
          _approving = false;
        }
      },
      openSession: (host, label) async {
        final session = TerminalSession('Agent · $label', host: host);
        if (!mounted || repo.locked) throw StateError('需要解锁 salp');
        setState(() {
          session.configureHighlight(repo);
          tabs.add(_Tab.terminal(session));
          active = tabs.length - 1;
        });
        if (host.protocol == Protocol.mosh) {
          await session.openMosh(
            repo,
            (h, a, f, p) => verifyHostDialog(context, h, a, f, p),
            (r) => authDialog(context, r),
          );
        } else {
          await session.openSsh(
            repo,
            (h, a, f, p) => verifyHostDialog(context, h, a, f, p),
            (r) => authDialog(context, r),
          );
        }
        return session;
      },
    );
    locked = repo.startupAuthentication && repo.masterPassword != null;
    repo.locked = locked;
    WidgetsBinding.instance.addPostFrameCallback((_) => reportRecovery());
    idleTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!locked &&
          repo.masterPassword != null &&
          repo.autoLockMinutes > 0 &&
          DateTime.now().difference(lastActivity).inMinutes >=
              repo.autoLockMinutes) {
        lock();
      }
    });
  }

  Future<void> reportRecovery() async {
    if (!Platform.isAndroid || _recoveryReported || locked || !mounted) return;
    try {
      final status = await AndroidDocuments.recoveryStatus();
      if (!mounted || locked) return;
      _recoveryReported = true;
      final recovered = status['recovered'] ?? 0;
      final uncertain = status['uncertain'] ?? 0;
      final pending = status['pending'] ?? 0;
      if (recovered + uncertain + pending == 0) return;
      ScaffoldMessenger.of(context).showMaterialBanner(
        MaterialBanner(
          content: Text(
            '上次下载已中断，已清理 $recovered 个临时文件。'
            '${uncertain > 0 ? ' $uncertain 个文件的完成状态未知，请在目标目录核对。' : ''}'
            '${pending > 0 ? ' $pending 个临时文件暂时无法清理，请恢复目标目录访问后重新打开应用。' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (_) {
      /* Native provider errors stay in its journal for next startup. */
    }
  }

  @override
  void dispose() {
    idleTimer?.cancel();
    PlatformLock.stop();
    unawaited(mcp.close());
    _activityFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isAndroid &&
        state == AppLifecycleState.paused &&
        !PlatformFiles.active &&
        repo.masterPassword != null) {
      lock();
    }
  }

  void lock() {
    repo.locked = true;
    repo.epoch++;
    Navigator.of(context).popUntil((route) => route.isFirst);
    for (final tab in tabs) {
      tab.terminal?.setLocked(true);
      tab.files?.setLocked(true);
      tab.desktop?.setLocked(true);
    }
    if (mounted) setState(() => locked = true);
  }

  Future<void> unlock(String password) async {
    if (repo.masterPassword == null ||
        !await MasterPassword.verify(password, repo.masterPassword!)) {
      throw StateError("主密码不正确");
    }
    if (osLocked) throw StateError('请先解锁系统会话');
    resumeUnlocked();
  }

  void resumeUnlocked() {
    repo.locked = false;
    repo.epoch++;
    for (final tab in tabs) {
      tab.terminal?.setLocked(false);
      tab.files?.setLocked(false);
      tab.desktop?.setLocked(false);
    }
    lastActivity = DateTime.now();
    if (mounted) setState(() => locked = false);
    unawaited(reportRecovery());
  }

  Future<void> importHosts() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => ImportDialog(repository: repo),
    );
    if (mounted) setState(() {});
  }

  Future<void> mcpSettings() async {
    final authority = repo.epoch;
    if (repo.masterPassword != null) {
      final password = await textDialog(context, '配置 MCP 前验证主密码', secret: true);
      if (password == null ||
          !await MasterPassword.verify(password, repo.masterPassword!)) {
        return;
      }
    }
    if (!mounted || repo.locked || repo.epoch != authority) return;
    await showDialog<void>(
      context: context,
      builder: (_) => McpDialog(repository: repo, server: mcp),
    );
  }

  Future<void> settings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _Settings(repository: repo),
    );
    for (final tab in tabs) {
      tab.terminal?.configureHighlight(repo);
    }
    if (mounted) setState(() {});
  }

  final _activityFocus = FocusNode();
  final tabs = <_Tab>[];
  int active = 0;
  int? split;
  Axis splitAxis = Axis.horizontal;
  String query = '';
  Repository get repo => widget.repository;
  Future<void> edit([Host? host]) async {
    final authority = repo.epoch;
    if (host != null && repo.masterPassword != null) {
      final password = await textDialog(context, '编辑凭据前验证主密码', secret: true);
      if (password == null || !mounted) return;
      if (!await MasterPassword.verify(password, repo.masterPassword!)) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('主密码不正确')));
        }
        return;
      }
    }
    if (!mounted || repo.locked || authority != repo.epoch) return;
    await showDialog<bool>(
      context: context,
      builder: (_) => HostEditor(repository: repo, host: host),
    );
    if (mounted) setState(() {});
  }

  Future<void> highlightHost(Host host) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => HighlightDialog(repository: repo, hostId: host.id),
    );
    if (!mounted) return;
    for (final tab in tabs) {
      tab.terminal?.configureHighlight(repo);
    }
  }

  Future<void> terminal(Host host) async {
    if (host.protocol == Protocol.vnc || host.protocol == Protocol.rdp) {
      final authority = repo.epoch;
      if (host.protocol == Protocol.vnc &&
          host.jumpIds.isEmpty &&
          !await confirmDialog(
            context,
            '连接未加密的 VNC？',
            '直连 VNC 的画面与键盘输入未加密，传统密码认证较弱。只在可信网络使用，或配置 SSH 跳板。',
          )) {
        return;
      }
      if (!mounted || repo.locked || repo.epoch != authority) return;
      final session = host.protocol == Protocol.rdp
          ? RdpSession(
              host,
              verifyCertificate: (details) => confirmDialog(
                context,
                '核对 RDP 证书',
                '系统无法自动信任此证书。请通过可信渠道核对以下信息；确认仅适用于本次连接。\n\n$details',
              ),
            )
          : VncSession(host);
      setState(() {
        tabs.add(_Tab.desktop(session));
        active = tabs.length - 1;
      });
      await session.open(
        repo,
        (h, a, f, p) => verifyHostDialog(context, h, a, f, p),
        (r) => authDialog(context, r),
      );
      return;
    }
    final session = TerminalSession(host.label, host: host);
    setState(() {
      session.configureHighlight(repo);
      tabs.add(_Tab.terminal(session));
      active = tabs.length - 1;
    });
    if (host.protocol == Protocol.telnet) {
      unawaited(session.openTelnet());
    } else if (host.protocol == Protocol.mosh) {
      unawaited(
        session.openMosh(
          repo,
          (h, a, f, p) => verifyHostDialog(context, h, a, f, p),
          (request) => authDialog(context, request),
        ),
      );
    } else {
      unawaited(
        session.openSsh(
          repo,
          (h, a, f, p) => verifyHostDialog(context, h, a, f, p),
          (request) => authDialog(context, request),
        ),
      );
    }
  }

  void files(Host host) {
    if (host.protocol != Protocol.ssh && host.protocol != Protocol.mosh) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('文件传输需要 SSH 主机')));
      return;
    }
    final session = SftpSession(host);
    setState(() {
      tabs.add(_Tab.files(session));
      active = tabs.length - 1;
    });
    unawaited(
      session.open(
        repo,
        (h, a, f, p) => verifyHostDialog(context, h, a, f, p),
        (request) => authDialog(context, request),
      ),
    );
  }

  void local() {
    final session = TerminalSession(Platform.isWindows ? 'PowerShell' : '本地终端');
    setState(() {
      session.configureHighlight(repo);
      tabs.add(_Tab.terminal(session));
      active = tabs.length - 1;
    });
    unawaited(session.openLocal());
  }

  Future<void> serial() async {
    final authority = repo.epoch;
    final settings = await showDialog<SerialSettings>(
      context: context,
      builder: (_) => SerialDialog(repository: repo),
    );
    if (settings == null ||
        !mounted ||
        repo.locked ||
        repo.epoch != authority) {
      return;
    }
    final session = TerminalSession(settings.path);
    setState(() {
      session.configureHighlight(repo);
      tabs.add(_Tab.terminal(session));
      active = tabs.length - 1;
    });
    await session.openSerial(
      settings.path,
      baud: settings.baud,
      bits: settings.bits,
      stopBits: settings.stopBits,
      parity: settings.parity,
      flow: settings.flow,
    );
  }

  Future<void> close(int index) async {
    final tab = tabs[index];
    try {
      await tab.close();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('关闭未完成，请重试')));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      tabs.remove(tab);
      active = active.clamp(0, tabs.isEmpty ? 0 : tabs.length - 1);
      split = null;
    });
  }

  Widget sidebar() => LayoutBuilder(
    builder: (context, constraints) {
      // Keep the host list usable when the keyboard or a short window leaves less
      // room than the fixed navigation actions need.
      final minimum =
          720.0 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
      if (constraints.maxHeight >= minimum) return sidebarContent();
      return SingleChildScrollView(
        child: SizedBox(height: minimum, child: sidebarContent()),
      );
    },
  );

  Widget sidebarContent() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 12, 16),
        child: Row(
          children: [
            const Icon(Icons.terminal, color: Color(0xff6bb9aa), size: 25),
            const SizedBox(width: 10),
            const Text(
              'salp',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            IconButton(
              tooltip: '新建主机',
              onPressed: edit,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          onChanged: (v) => setState(() => query = v.toLowerCase()),
          decoration: const InputDecoration(
            hintText: '搜索主机、地址或分组',
            prefixIcon: Icon(Icons.search, size: 20),
          ),
        ),
      ),
      const SizedBox(height: 20),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(
          '主机  ${repo.hosts.length}',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: ListView(
          children: [
            for (final host in repo.hosts.where(
              (h) => '${h.label} ${h.address} ${h.group}'
                  .toLowerCase()
                  .contains(query),
            ))
              ListTile(
                leading: const Icon(Icons.dns_outlined, size: 20),
                title: Text(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${host.group.isEmpty ? '' : '${host.group} · '}${host.username}@${host.address}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => terminal(host),
                trailing: PopupMenuButton<String>(
                  tooltip: '主机操作',
                  onSelected: (v) async {
                    if (v == 'ssh') terminal(host);
                    if (v == 'sftp') files(host);
                    if (v == 'edit') await edit(host);
                    if (v == 'highlight') await highlightHost(host);
                    if (v == 'delete' &&
                        mounted &&
                        await confirmDialog(
                          context,
                          '删除主机？',
                          '${host.label}\n会移除主机配置和保存的凭据，不会删除远端数据。',
                        )) {
                      if (repo.hosts.any((h) => h.jumpIds.contains(host.id))) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('此主机仍被用作跳板，请先修改相关路径')),
                          );
                        }
                        return;
                      }
                      final authority = repo.epoch;
                      try {
                        await repo.update((draft) {
                          if (draft.hosts.any(
                            (h) => h.jumpIds.contains(host.id),
                          )) {
                            throw StateError('此主机仍被用作跳板');
                          }
                          draft.hosts.removeWhere((h) => h.id == host.id);
                          draft.credentials.remove(host.id);
                          draft.hostHighlight.remove(host.id);
                        }, authority: authority);
                      } catch (_) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('删除未完成，现有配置已保留')),
                          );
                        }
                      }
                      if (mounted) setState(() {});
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'ssh', child: Text('连接终端')),
                    PopupMenuItem(value: 'sftp', child: Text('打开文件传输')),
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'highlight', child: Text('此主机着色规则')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ),
          ],
        ),
      ),
      const Divider(height: 1),
      if (!Platform.isAndroid)
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text('本地终端'),
          onTap: local,
        ),
      if (!Platform.isAndroid)
        ListTile(
          leading: const Icon(Icons.usb),
          title: const Text('串口终端'),
          onTap: serial,
        ),
      ListTile(
        leading: const Icon(Icons.add_circle_outline),
        title: const Text('新建主机'),
        onTap: edit,
      ),
      ListTile(
        leading: const Icon(Icons.file_open_outlined),
        title: const Text('导入配置'),
        onTap: importHosts,
      ),
      if (!Platform.isAndroid)
        ListTile(
          leading: const Icon(Icons.smart_toy_outlined),
          title: const Text('MCP 代理'),
          onTap: mcpSettings,
        ),
      ListTile(
        leading: const Icon(Icons.settings_outlined),
        title: const Text('设置'),
        onTap: settings,
      ),
      ListTile(
        leading: const Icon(Icons.lock_outline),
        title: const Text('锁定应用'),
        onTap: repo.masterPassword == null ? settings : lock,
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Text(
          '凭据由系统安全存储保护',
          style: TextStyle(fontSize: 11, color: Color(0xffa0abb7)),
        ),
      ),
    ],
  );
  Widget tabView(_Tab tab) {
    if (tab.desktop != null) {
      return VncView(key: ObjectKey(tab), session: tab.desktop!);
    }
    if (tab.files != null) {
      return SftpView(key: ObjectKey(tab), session: tab.files!);
    }
    final session = tab.terminal!;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Column(
        children: [
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: const Color(0xff171b20),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 7,
                  color: session.connected
                      ? const Color(0xff6bb9aa)
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${session.host == null ? '本机' : '${session.host!.username}@${session.host!.endpoint}'} · ${session.status}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (session.connected && session.ssh != null)
                  IconButton(
                    tooltip: 'SSH 隧道',
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => TunnelDialog(session: session),
                    ),
                    icon: const Icon(Icons.route_outlined, size: 18),
                  ),
                if (session.host != null)
                  IconButton(
                    tooltip: '打开独立 SFTP 标签',
                    onPressed: () => files(session.host!),
                    icon: const Icon(Icons.folder_outlined, size: 18),
                  ),
                PopupMenuButton<String>(
                  tooltip: '会话工具',
                  icon: const Icon(Icons.more_vert, size: 18),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'snippets', child: Text('命令片段')),
                    PopupMenuItem(
                      value: 'log',
                      child: Text(session.log == null ? '开始本地加密日志' : '停止记录日志'),
                    ),
                    const PopupMenuItem(value: 'logs', child: Text('查看本地日志')),
                    if (session.host != null)
                      const PopupMenuItem(
                        value: 'highlight',
                        child: Text('此主机着色规则'),
                      ),
                  ],
                  onSelected: (action) async {
                    if (action == 'snippets') {
                      await showDialog<void>(
                        context: context,
                        builder: (_) =>
                            SnippetsDialog(repository: repo, session: session),
                      );
                    } else if (action == 'highlight') {
                      await highlightHost(session.host!);
                    } else if (action == 'logs') {
                      final authority = repo.epoch;
                      if (repo.masterPassword != null) {
                        final password = await textDialog(
                          context,
                          '查看日志前验证主密码',
                          secret: true,
                        );
                        if (password == null ||
                            !await MasterPassword.verify(
                              password,
                              repo.masterPassword!,
                            )) {
                          return;
                        }
                      }
                      if (!context.mounted ||
                          repo.locked ||
                          repo.epoch != authority) {
                        return;
                      }
                      await showDialog<void>(
                        context: context,
                        builder: (_) => LogsDialog(repository: repo),
                      );
                    } else if (session.log != null) {
                      await session.stopLog();
                    } else {
                      final authority = repo.epoch;
                      final accepted = await confirmDialog(
                        context,
                        '记录此会话的输出？',
                        '日志可能包含机密；以加密形式仅保存在本机，最多 16 MiB，7 天后清理。',
                      );
                      if (!accepted ||
                          !context.mounted ||
                          repo.locked ||
                          repo.epoch != authority) {
                        return;
                      }
                      try {
                        await session.startLog(repo);
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('日志创建失败')),
                          );
                        }
                      }
                    }
                  },
                ),
                IconButton(
                  tooltip: '粘贴',
                  onPressed: session.connected
                      ? () async {
                          final generation = session.input.generation;
                          final data = await Clipboard.getData(
                            Clipboard.kTextPlain,
                          );
                          if (data?.text != null &&
                              !session.closed &&
                              !session.input.locked &&
                              session.input.generation == generation) {
                            session.terminal.paste(data!.text!);
                          }
                        }
                      : null,
                  icon: const Icon(Icons.content_paste, size: 18),
                ),
              ],
            ),
          ),
          if (session.error != null)
            MaterialBanner(
              content: Text(session.error!),
              actions: [
                if (!session.connected && session.host != null)
                  TextButton(
                    onPressed: () => terminal(session.host!),
                    child: const Text('重新连接'),
                  ),
                TextButton(
                  onPressed: () => setState(() => session.error = null),
                  child: const Text('关闭提示'),
                ),
              ],
            ),
          Expanded(
            child: TerminalView(
              session.terminal,
              autofocus: true,
              readOnly: !session.connected,
              deleteDetection: Platform.isAndroid,
              padding: const EdgeInsets.all(12),
              textStyle: const TerminalStyle(
                fontSize: 14,
                fontFamily: 'monospace',
              ),
            ),
          ),
          if (Platform.isAndroid)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final key in {
                    'Esc': '\x1b',
                    'Tab': '\t',
                    'Ctrl-C': '\x03',
                    'Ctrl-D': '\x04',
                    '↑': '\x1b[A',
                    '↓': '\x1b[B',
                    '←': '\x1b[D',
                    '→': '\x1b[C',
                  }.entries)
                    TextButton(
                      onPressed: () => session.send(key.value),
                      child: Text(key.key),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget workspace() => Column(
    children: [
      SizedBox(
        height: 48,
        child: Row(
          children: [
            if (MediaQuery.sizeOf(context).width < 760)
              Builder(
                builder: (context) => IconButton(
                  tooltip: '主机列表',
                  onPressed: () => Scaffold.of(context).openDrawer(),
                  icon: const Icon(Icons.menu),
                ),
              ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Container(
                      decoration: BoxDecoration(
                        color: i == active ? const Color(0xff222b33) : null,
                        border: Border(
                          bottom: BorderSide(
                            color: i == active
                                ? const Color(0xff6bb9aa)
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: InkWell(
                        onTap: () => setState(() => active = i),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Row(
                            children: [
                              Icon(
                                tabs[i].files == null
                                    ? Icons.terminal
                                    : Icons.folder_outlined,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 180,
                                ),
                                child: Text(
                                  tabs[i].title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                tooltip: '关闭会话',
                                iconSize: 16,
                                onPressed: () => close(i),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (tabs.length > 1 && MediaQuery.sizeOf(context).width >= 760)
              IconButton(
                tooltip: '切换分屏',
                onPressed: () => setState(
                  () =>
                      split = split == null ? (active + 1) % tabs.length : null,
                ),
                icon: const Icon(Icons.vertical_split_outlined),
              ),
            if (split != null && MediaQuery.sizeOf(context).width >= 760)
              IconButton(
                tooltip: '切换分屏方向',
                icon: Icon(
                  splitAxis == Axis.horizontal
                      ? Icons.splitscreen
                      : Icons.view_column_outlined,
                ),
                onPressed: () => setState(
                  () => splitAxis = splitAxis == Axis.horizontal
                      ? Axis.vertical
                      : Axis.horizontal,
                ),
              ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: tabs.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.terminal,
                        size: 48,
                        color: Color(0xff6bb9aa),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        '连接到你的工作现场',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '添加主机，打开终端或文件传输。',
                        style: TextStyle(color: Color(0xffa0abb7)),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: edit,
                        icon: const Icon(Icons.add),
                        label: const Text('新建主机'),
                      ),
                    ],
                  ),
                ),
              )
            : split != null &&
                  split != active &&
                  split! < tabs.length &&
                  MediaQuery.sizeOf(context).width >= 760
            ? SplitPane(
                axis: splitAxis,
                first: tabView(tabs[active]),
                second: tabView(tabs[split!]),
              )
            : tabView(tabs[active]),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 760;
    if (locked) {
      if (osLocked || repo.masterPassword == null) {
        return const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 36),
                SizedBox(height: 16),
                Text('等待系统解锁'),
                SizedBox(height: 12),
                Text('连接保留，系统身份验证完成后恢复。'),
              ],
            ),
          ),
        );
      }
      return _LockScreen(onUnlock: unlock);
    }
    return Listener(
      onPointerDown: (_) => lastActivity = DateTime.now(),
      onPointerSignal: (_) => lastActivity = DateTime.now(),
      child: KeyboardListener(
        focusNode: _activityFocus,
        onKeyEvent: (_) => lastActivity = DateTime.now(),
        child: Scaffold(
          drawer: narrow ? Drawer(child: SafeArea(child: sidebar())) : null,
          body: SafeArea(
            child: Row(
              children: [
                if (!narrow) ...[
                  SizedBox(width: 264, child: sidebar()),
                  const VerticalDivider(width: 1),
                ],
                Expanded(child: workspace()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({required this.onUnlock});
  final Future<void> Function(String) onUnlock;
  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  final password = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.onUnlock(password.text);
      password.clear();
    } catch (_) {
      if (mounted) setState(() => error = '主密码不正确或验证失败');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 40),
              const SizedBox(height: 20),
              const Text('salp 已锁定', style: TextStyle(fontSize: 24)),
              const SizedBox(height: 12),
              const Text('连接保留，解锁后继续工作。'),
              const SizedBox(height: 24),
              TextField(
                controller: password,
                obscureText: true,
                autofocus: true,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(labelText: '主密码', errorText: error),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(busy ? '正在验证…' : '解锁'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Settings extends StatefulWidget {
  const _Settings({required this.repository});
  final Repository repository;
  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  bool busy = false;
  String? error;
  Future<void> master() async {
    final repo = widget.repository;
    final authority = repo.epoch;
    String? old;
    if (repo.masterPassword != null) {
      old = await textDialog(context, '验证当前主密码', secret: true);
      if (old == null) return;
      if (!await MasterPassword.verify(old, repo.masterPassword!)) {
        if (mounted) setState(() => error = '主密码不正确');
        return;
      }
    }
    if (!mounted) return;
    final password = await textDialog(context, '设置主密码（至少 8 字符）', secret: true);
    if (password == null || !mounted) return;
    final confirmation = await textDialog(context, '再次输入主密码', secret: true);
    if (confirmation != password) {
      if (mounted) setState(() => error = '两次输入不一致');
      return;
    }
    setState(() => busy = true);
    try {
      repo.checkAuthority(authority);
      await changeMasterPassword(repo, old, password);
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              error = e is SyncException ? e.toString() : '主密码设置未完成，请重新检查同步状态',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设置'),
    scrollable: true,
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              widget.repository.masterPassword == null ? '设置主密码' : '更改主密码',
            ),
            subtitle: const Text('用于应用锁定；忘记后无法通过此验证'),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : master,
          ),
          ListTile(
            title: const Text('终端规则着色'),
            subtitle: const Text('字面量 / 正则 · ANSI 颜色优先'),
            trailing: const Icon(Icons.palette_outlined),
            onTap: busy
                ? null
                : () => showDialog<bool>(
                    context: context,
                    builder: (_) =>
                        HighlightDialog(repository: widget.repository),
                  ),
          ),
          ListTile(
            title: const Text('WebDAV 加密同步'),
            subtitle: const Text('主机、凭据和片段；冲突保留双方'),
            trailing: const Icon(Icons.sync),
            onTap: busy
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (_) => SyncDialog(repository: widget.repository),
                  ),
          ),
          SwitchListTile(
            title: const Text('启动时验证主密码'),
            subtitle: const Text('默认关闭；关闭时使用系统密钥库自动打开'),
            value: widget.repository.startupAuthentication,
            onChanged: busy || widget.repository.masterPassword == null
                ? null
                : (value) async {
                    final repo = widget.repository;
                    final authority = repo.epoch;
                    final password = await textDialog(
                      context,
                      '验证主密码以更改启动保护',
                      secret: true,
                    );
                    if (password == null || !mounted) return;
                    setState(() => busy = true);
                    try {
                      await repo.setStartupAuthentication(
                        value,
                        password,
                        authority,
                      );
                      if (mounted) setState(() => error = null);
                    } catch (_) {
                      if (mounted) {
                        setState(() => error = '未更改启动保护，请检查主密码或重新打开设置');
                      }
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
          ),
          DropdownButtonFormField<int>(
            initialValue: widget.repository.autoLockMinutes,
            decoration: const InputDecoration(labelText: '空闲后自动锁定'),
            items: [0, 5, 15, 30, 60]
                .map(
                  (m) => DropdownMenuItem(
                    value: m,
                    child: Text(m == 0 ? '关闭' : '$m 分钟'),
                  ),
                )
                .toList(),
            onChanged: (m) async {
              if (m != null) {
                try {
                  await widget.repository.update(
                    (draft) => draft.autoLockMinutes = m,
                  );
                } catch (_) {
                  if (mounted) setState(() => error = '自动锁定设置未保存');
                }
              }
            },
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!),
            ),
          const SizedBox(height: 16),
          const Text('salp · GPL-3.0-or-later', style: TextStyle(fontSize: 12)),
          TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'salp',
              applicationVersion: '0.1.0',
            ),
            child: const Text('第三方许可证'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
