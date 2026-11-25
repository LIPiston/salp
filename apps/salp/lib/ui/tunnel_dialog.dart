import 'package:material_ui/material_ui.dart';

import '../core/tunnels.dart';
import '../core/connection.dart';

class TunnelDialog extends StatefulWidget {
  const TunnelDialog({super.key, required this.session});
  final TerminalSession session;
  @override
  State<TunnelDialog> createState() => _TunnelDialogState();
}

class _TunnelDialogState extends State<TunnelDialog> {
  String type = 'local';
  final listen = TextEditingController(text: '8080'),
      host = TextEditingController(text: '127.0.0.1'),
      port = TextEditingController(text: '80');
  bool busy = false;
  String? error;
  @override
  void dispose() {
    listen.dispose();
    host.dispose();
    port.dispose();
    super.dispose();
  }

  Future<void> create() async {
    final lp = int.tryParse(listen.text), rp = int.tryParse(port.text);
    if (lp == null ||
        lp < 0 ||
        lp > 65535 ||
        (type != 'dynamic' && (rp == null || rp < 1 || rp > 65535))) {
      setState(() => error = '请输入有效端口');
      return;
    }
    setState(() => busy = true);
    try {
      final ssh = widget.session.ssh!.client;
      final tunnel = await switch (type) {
        'local' => Tunnel.local(ssh, lp, host.text, rp!),
        'remote' => Tunnel.remote(ssh, lp, host.text, rp!),
        _ => Tunnel.dynamic(ssh, lp),
      };
      widget.session.tunnels.add(tunnel);
      if (mounted) setState(() => error = null);
    } catch (_) {
      if (mounted) setState(() => error = '转发创建失败，端口可能被占用或服务器不允许');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('SSH 隧道'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: type,
              items: const [
                DropdownMenuItem(value: 'local', child: Text('本地转发')),
                DropdownMenuItem(value: 'remote', child: Text('远端转发')),
                DropdownMenuItem(value: 'dynamic', child: Text('动态 SOCKS5')),
              ],
              onChanged: (v) => setState(() => type = v!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: listen,
              decoration: const InputDecoration(labelText: '监听端口（0 自动分配）'),
            ),
            if (type != 'dynamic') ...[
              const SizedBox(height: 12),
              TextField(
                controller: host,
                decoration: const InputDecoration(labelText: '目标地址'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: port,
                decoration: const InputDecoration(labelText: '目标端口'),
              ),
            ],
            if (error != null) Text(error!),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : create,
              child: const Text('创建隧道'),
            ),
            for (final tunnel in widget.session.tunnels.where((t) => t.active))
              ListTile(
                title: Text(tunnel.description),
                trailing: IconButton(
                  onPressed: () async {
                    await tunnel.close();
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
              ),
          ],
        ),
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
