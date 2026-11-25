import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../core/highlight.dart';
import '../core/repository.dart';

class HighlightDialog extends StatefulWidget {
  const HighlightDialog({super.key, required this.repository, this.hostId});
  final String? hostId;
  final Repository repository;
  @override
  State<HighlightDialog> createState() => _HighlightDialogState();
}

class _HighlightDialogState extends State<HighlightDialog> {
  final pattern = TextEditingController();
  final terminal = Terminal()
    ..write(
      'ERROR: connection refused\r\nWARN: retrying\r\nOK: connected 中文\r\n\x1b[34mERROR with explicit ANSI\x1b[0m',
    );
  late final authority = widget.repository.epoch;
  late List<HighlightRule> rules;
  bool inherit = false;
  late final highlighter = TerminalHighlighter(terminal, rules);
  bool enabled = true, regex = false, wholeLine = false, busy = false;
  int color = 0xffe98686;
  String? error;
  @override
  void initState() {
    super.initState();
    final override = widget.repository.hostHighlight[widget.hostId];
    inherit = widget.hostId != null && override == null;
    enabled = override == null
        ? widget.repository.highlightEnabled
        : override['enabled'] == true;
    rules =
        (override == null
                ? widget.repository.highlightRules
                : (override['rules'] as List).map(
                    (r) => Map<String, dynamic>.from(r as Map),
                  ))
            .map(HighlightRule.fromJson)
            .toList();
    refresh();
  }

  @override
  void dispose() {
    highlighter.dispose();
    pattern.dispose();
    super.dispose();
  }

  void refresh() => highlighter.update(
    inherit
        ? (widget.repository.highlightEnabled
              ? widget.repository.highlightRules
                    .map(HighlightRule.fromJson)
                    .toList()
              : [])
        : enabled
        ? rules
        : [],
  );
  void add() {
    try {
      final rule = HighlightRule(
        pattern.text,
        color,
        regex: regex,
        wholeLine: wholeLine,
      )..validate();
      if (rules.length >= 64) throw const FormatException('最多 64 条规则');
      setState(() {
        rules.add(rule);
        pattern.clear();
        error = null;
        refresh();
      });
    } catch (e) {
      setState(() => error = e is FormatException ? e.message : '规则无效');
    }
  }

  Future<void> save() async {
    final repo = widget.repository;
    final nextRules = rules.map((r) => r.toJson()).toList();
    final nextEnabled = enabled;
    setState(() => busy = true);
    try {
      repo.checkAuthority(authority);
      await repo.update((draft) {
        if (widget.hostId == null) {
          draft.highlightRules = nextRules;
          draft.highlightEnabled = nextEnabled;
        } else if (inherit) {
          draft.hostHighlight.remove(widget.hostId);
        } else {
          draft.hostHighlight[widget.hostId!] = {
            'enabled': nextEnabled,
            'rules': nextRules,
          };
        }
      }, authority: authority);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => error = '保存失败或授权失效');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.hostId == null ? '终端规则着色' : '此主机的着色规则'),
    content: SizedBox(
      width: 680,
      height: MediaQuery.sizeOf(context).height * .7,
      child: ListView(
        children: [
          if (widget.hostId != null)
            SwitchListTile(
              title: const Text('继承全局规则'),
              value: inherit,
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      inherit = v;
                      refresh();
                    }),
            ),
          if (inherit) const Text('预览使用全局规则；关闭继承后可保存独立规则。'),
          SwitchListTile(
            title: const Text('启用规则着色'),
            subtitle: const Text('保留程序显式 ANSI 颜色，仅改变显示'),
            value: enabled,
            onChanged: busy || inherit
                ? null
                : (v) => setState(() {
                    enabled = v;
                    refresh();
                  }),
          ),
          const Text('按列表顺序匹配，先匹配的规则优先。正则在独立任务中计算，超时仅停用当前会话着色。'),
          for (final (index, rule) in rules.indexed)
            ListTile(
              leading: Icon(Icons.circle, color: Color(rule.color), size: 14),
              title: Text(rule.pattern),
              subtitle: Text(
                '${rule.regex ? '正则' : '字面量'} · ${rule.wholeLine ? '整行' : '匹配段'}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '提高优先级',
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: busy || inherit || index == 0
                        ? null
                        : () => setState(() {
                            rules.removeAt(index);
                            rules.insert(index - 1, rule);
                            refresh();
                          }),
                  ),
                  IconButton(
                    tooltip: '删除规则',
                    icon: const Icon(Icons.close),
                    onPressed: busy || inherit
                        ? null
                        : () => setState(() {
                            rules.removeAt(index);
                            refresh();
                          }),
                  ),
                ],
              ),
            ),
          TextField(
            controller: pattern,
            enabled: !busy && !inherit,
            maxLength: 256,
            decoration: const InputDecoration(labelText: '匹配内容或正则'),
          ),
          Wrap(
            children: [
              FilterChip(
                label: const Text('正则表达式'),
                selected: regex,
                onSelected: busy || inherit
                    ? null
                    : (v) => setState(() => regex = v),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('整行着色'),
                selected: wholeLine,
                onSelected: busy || inherit
                    ? null
                    : (v) => setState(() => wholeLine = v),
              ),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: color,
                items:
                    const {
                          0xffe98686: '红',
                          0xffe1c480: '黄',
                          0xff6bb9aa: '青绿',
                          0xff84b6e8: '蓝',
                          0xffcda0e8: '紫',
                        }.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(
                              e.value,
                              style: TextStyle(color: Color(e.key)),
                            ),
                          ),
                        )
                        .toList(),
                onChanged: busy || inherit
                    ? null
                    : (v) => setState(() => color = v!),
              ),
              TextButton(
                onPressed: busy || inherit ? null : add,
                child: const Text('添加并预览'),
              ),
            ],
          ),
          if (error != null) Text(error!),
          SizedBox(
            height: 150,
            child: TerminalView(
              terminal,
              readOnly: true,
              textStyle: const TerminalStyle(
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: busy ? null : save, child: const Text('保存规则')),
    ],
  );
}
