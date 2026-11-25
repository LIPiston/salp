import 'package:material_ui/material_ui.dart';

import '../core/serial.dart';
import '../core/serial_profile.dart';
import '../core/repository.dart';
import 'dialogs.dart';
export '../core/serial_profile.dart';

class SerialDialog extends StatefulWidget {
  const SerialDialog({super.key, required this.repository});
  final Repository repository;
  @override
  State<SerialDialog> createState() => _SerialDialogState();
}

class _SerialDialogState extends State<SerialDialog> {
  late final authority = widget.repository.epoch;
  final name = TextEditingController();
  bool busy = false;
  final path = TextEditingController(),
      baud = TextEditingController(text: '115200');
  int bits = 8, stopBits = 1, parity = 0, flow = 0;
  List<String> ports = [];
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  void refresh() {
    try {
      ports = SerialConnection.listPorts();
      error = null;
    } catch (e) {
      error = e.toString();
    }
  }

  @override
  void dispose() {
    name.dispose();
    path.dispose();
    baud.dispose();
    super.dispose();
  }

  SerialSettings settings() {
    final value = SerialSettings(
      path.text.trim(),
      int.tryParse(baud.text) ?? 0,
      bits,
      stopBits,
      parity,
      flow,
    );
    value.validate();
    return value;
  }

  void load(String label) {
    try {
      widget.repository.checkAuthority(authority);
      final value = SerialSettings.fromJson(
        widget.repository.serialProfiles[label]!,
      );
      setState(() {
        name.text = label;
        path.text = value.path;
        baud.text = '${value.baud}';
        bits = value.bits;
        stopBits = value.stopBits;
        parity = value.parity;
        flow = value.flow;
        error = null;
      });
    } catch (_) {
      setState(() => error = '配置不可读取或授权已失效');
    }
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      final label = name.text.trim(), value = settings();
      if (widget.repository.serialProfiles.containsKey(label) &&
          !await confirmDialog(context, '替换串口配置？', '将替换本机保存的“$label”参数。')) {
        return;
      }
      if (!mounted) return;
      await widget.repository.saveSerialProfile(label, value, authority);
      if (mounted) setState(() => error = '已保存配置');
    } catch (e) {
      if (mounted) {
        setState(() => error = e is FormatException ? e.message : '保存失败或授权已失效');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove(String label) async {
    if (!await confirmDialog(context, '删除串口配置？', '删除本机配置“$label”。')) return;
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.repository.removeSerialProfile(label, authority);
      if (mounted) setState(() => error = null);
    } catch (_) {
      if (mounted) setState(() => error = '删除失败或授权已失效');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget choice(
    String label,
    int value,
    Map<int, String> options,
    ValueChanged<int> update,
  ) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: DropdownButtonFormField<int>(
      key: ValueKey('$label:$value'),
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: options.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: busy ? null : (v) => setState(() => update(v!)),
    ),
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('串口终端'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('配置仅保存在本机，不同步设备路径。载入配置后点击打开串口连接。'),
            for (final label in widget.repository.serialProfiles.keys)
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: busy ? null : () => load(label),
                      child: Text('载入：$label'),
                    ),
                  ),
                  IconButton(
                    onPressed: busy ? null : () => remove(label),
                    tooltip: '删除$label',
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            TextField(
              controller: name,
              enabled: !busy,
              decoration: const InputDecoration(labelText: '配置名称'),
            ),
            OutlinedButton(
              onPressed: busy ? null : save,
              child: const Text('保存当前配置'),
            ),
            Row(
              children: [
                const Expanded(child: Text('选择设备或填写设备路径')),
                IconButton(
                  onPressed: busy ? null : () => setState(refresh),
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新设备',
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: ports
                  .map(
                    (p) => ActionChip(
                      label: Text(p),
                      onPressed: busy
                          ? null
                          : () => setState(() => path.text = p),
                    ),
                  )
                  .toList(),
            ),
            TextField(
              enabled: !busy,
              controller: path,
              decoration: const InputDecoration(
                labelText: '设备路径',
                hintText: '/dev/ttyUSB0 或 COM3',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              enabled: !busy,
              controller: baud,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '波特率'),
            ),
            choice('数据位', bits, {
              5: '5',
              6: '6',
              7: '7',
              8: '8',
            }, (v) => bits = v),
            choice('停止位', stopBits, {1: '1', 2: '2'}, (v) => stopBits = v),
            choice('校验', parity, {
              0: '无',
              1: '奇校验',
              2: '偶校验',
              3: 'Mark',
              4: 'Space',
            }, (v) => parity = v),
            choice('流控制', flow, {
              0: '无',
              1: 'XON/XOFF',
              2: 'RTS/CTS',
            }, (v) => flow = v),
            if (error != null) Text(error!),
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
        onPressed: busy
            ? null
            : () {
                try {
                  widget.repository.checkAuthority(authority);
                  Navigator.pop(context, settings());
                } catch (_) {
                  setState(() => error = '请输入有效串口参数，并确认应用已解锁');
                }
              },
        child: const Text('打开串口'),
      ),
    ],
  );
}
