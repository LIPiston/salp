import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bounded_read.dart';

import 'host.dart';

class ImportPreview {
  final hosts = <Host>[];
  final warnings = <String>[];
}

class _Block {
  _Block(this.patterns);
  final List<String> patterns;
  final values = <String, String>{};
}

List<String> _words(String line) {
  final result = <String>[];
  var current = StringBuffer();
  String? quote;
  var escape = false;
  for (final rune in line.runes) {
    final c = String.fromCharCode(rune);
    if (escape) {
      current.write(c);
      escape = false;
      continue;
    }
    if (c == r'\') {
      escape = true;
      continue;
    }
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        current.write(c);
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if (c == '#') break;
    if (c.trim().isEmpty || c == '=') {
      if (current.isNotEmpty) {
        result.add(current.toString());
        current = StringBuffer();
      }
    } else {
      current.write(c);
    }
  }
  if (quote != null || escape) throw const FormatException('配置引号或转义未结束');
  if (current.isNotEmpty) result.add(current.toString());
  return result;
}

bool _glob(String pattern, String host) => RegExp(
  '^${pattern.split('').map((c) => c == '*'
      ? '.*'
      : c == '?'
      ? '.'
      : RegExp.escape(c)).join()}\$',
  caseSensitive: false,
).hasMatch(host);
bool _matches(List<String> patterns, String host) {
  if (patterns
      .where((p) => p.startsWith('!'))
      .any((p) => _glob(p.substring(1), host))) {
    return false;
  }
  return patterns.where((p) => !p.startsWith('!')).any((p) => _glob(p, host));
}

/// Resolve Include only under an explicitly selected local directory. Relative
/// includes and ~/ are rooted there (select ~/.ssh for normal user configs).
Future<ImportPreview> parseOpenSshFile(
  File source,
  Directory selectedRoot,
  void Function() authorize,
) async {
  authorize();
  final root = await selectedRoot.resolveSymbolicLinks();
  authorize();
  var total = 0, files = 0;
  var conditional = false;
  final warnings = <String>[];
  Future<String> expand(File file, Set<String> stack) async {
    authorize();
    final real = await file.resolveSymbolicLinks();
    authorize();
    if (!p.isWithin(root, real)) throw const FormatException('Include超出所选目录');
    if (stack.contains(real) || stack.length >= 16 || ++files > 128) {
      throw const FormatException('Include循环、深度或文件数量超过限制');
    }
    final bytes = await readBounded(
      File(real).openRead(),
      maxBytes: 4 * 1024 * 1024 - total,
      authorize: authorize,
    );
    total += bytes.length;
    final result = StringBuffer();
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      authorize();
      final words = _words(line);
      if (words.isNotEmpty &&
          {'host', 'match'}.contains(words.first.toLowerCase())) {
        conditional = true;
      }
      if (words.isEmpty || words.first.toLowerCase() != 'include') {
        result.writeln(line);
        continue;
      }
      if (conditional) {
        throw const FormatException(
          '暂不展开Host/Match条件块内的Include，请整理为文件顶部Include后重试',
        );
      }
      if (words.length < 2) throw const FormatException('Include缺少路径');
      for (var pattern in words.skip(1)) {
        if (pattern.contains('%') ||
            pattern.contains(r'$') ||
            pattern.contains('[') ||
            pattern.contains(']')) {
          throw const FormatException('Include暂不支持变量或字符集合匹配');
        }
        if (pattern.startsWith('~/')) pattern = pattern.substring(2);
        if (pattern.startsWith('~')) {
          throw const FormatException('Include用户目录不在所选范围');
        }
        final absolute = p.normalize(
          p.isAbsolute(pattern) ? pattern : p.join(root, pattern),
        );
        if (!p.isWithin(root, absolute)) {
          throw const FormatException('Include超出所选目录');
        }
        var candidates = <String>[root];
        for (final segment in p.split(p.relative(absolute, from: root))) {
          final next = <String>[];
          for (final directory in candidates) {
            authorize();
            if (segment.contains('*') || segment.contains('?')) {
              var seen = 0;
              if (!await Directory(directory).exists()) continue;
              await for (final entry in Directory(
                directory,
              ).list(followLinks: false)) {
                authorize();
                if (++seen > 10000) {
                  throw const FormatException('Include目录条目过多');
                }
                if (_glob(segment, p.basename(entry.path))) {
                  next.add(entry.path);
                }
              }
            } else {
              final path = p.join(directory, segment);
              if (await FileSystemEntity.type(path, followLinks: false) !=
                  FileSystemEntityType.notFound) {
                next.add(path);
              }
            }
          }
          candidates = [];
          for (final candidate in next) {
            final resolved = await File(candidate).resolveSymbolicLinks();
            authorize();
            if (!p.isWithin(root, resolved)) {
              throw const FormatException('Include符号链接超出所选目录');
            }
            candidates.add(resolved);
          }
          if (candidates.length > 128) {
            throw const FormatException('Include匹配文件过多');
          }
        }
        candidates.sort();
        if (candidates.isEmpty) warnings.add('Include $pattern 未匹配文件');
        for (final candidate in candidates) {
          if (await FileSystemEntity.type(candidate) !=
              FileSystemEntityType.file) {
            throw const FormatException('Include目标不是普通文件');
          }
          result.writeln(await expand(File(candidate), {...stack, real}));
        }
      }
    }
    return result.toString();
  }

  final expanded = await expand(source, {});
  authorize();
  final preview = parseOpenSsh(expanded);
  preview.warnings.insertAll(0, warnings);
  preview.warnings.add('Include已在所选目录内展开；相对路径及~/以该目录为根。行号为展开后的行号。未执行任何配置命令。');
  return preview;
}

ImportPreview parseOpenSsh(String source) {
  final preview = ImportPreview();
  final blocks = <_Block>[
    _Block(['*']),
  ];
  final aliases = <String>{};
  var current = blocks.first;
  var ignore = false;
  var lineNo = 0;
  const supported = {'hostname', 'user', 'port', 'proxyjump'};
  for (final line in const LineSplitter().convert(source)) {
    lineNo++;
    List<String> words;
    try {
      words = _words(line);
    } on FormatException {
      preview.warnings.add('第 $lineNo 行语法无效，未导入');
      continue;
    }
    if (words.isEmpty) continue;
    final keyword = words.first;
    final key = keyword.toLowerCase();
    if (key == 'host') {
      current = _Block(words.skip(1).toList());
      blocks.add(current);
      ignore = false;
      aliases.addAll(
        current.patterns.where((p) => !RegExp(r'[*?!]').hasMatch(p)),
      );
    } else if (key == 'match') {
      ignore = true;
      preview.warnings.add('第 $lineNo 行 Match 条件未导入；其后的条件配置跳过');
    } else if (!ignore) {
      if (supported.contains(key) && words.length == 2) {
        current.values.putIfAbsent(key, () => words[1]);
      } else {
        if (key == 'proxycommand' || key == 'include') {
          current.values.putIfAbsent(key, () => words.skip(1).join(' '));
        }
        preview.warnings.add(
          '第 $lineNo 行 $keyword 未导入${key == 'identityfile' ? '：请通过主机编辑器手动选择私钥' : ''}',
        );
      }
    }
  }
  final candidates = <String, Host>{};
  final jumps = <String, List<String>>{};
  for (final alias in aliases) {
    final options = <String, String>{};
    for (final block in blocks.where((b) => _matches(b.patterns, alias))) {
      for (final entry in block.values.entries) {
        options.putIfAbsent(entry.key, () => entry.value);
      }
    }
    if (options.containsKey('include') ||
        (options.containsKey('proxycommand') &&
            options['proxycommand']!.toLowerCase() != 'none')) {
      preview.warnings.add('$alias：包含未解析的路由或 Include，整项跳过；请手动配置');
      continue;
    }
    final host = Host(
      id: Host.newId(),
      name: alias,
      address: options['hostname'] ?? alias,
      username: options['user'] ?? 'root',
      port: int.tryParse(options['port'] ?? '22') ?? 0,
    );
    try {
      host.validate();
    } on FormatException {
      preview.warnings.add('$alias：主机或端口无效，未导入');
      continue;
    }
    if (!options.containsKey('user')) {
      preview.warnings.add('$alias：未指定 User，暂使用 root，请在预览后确认');
    }
    if (host.address.contains('%') || host.username.contains('%')) {
      preview.warnings.add('$alias：配置变量展开未实现，未导入');
      continue;
    }
    candidates[alias] = host;
    final jump = options['proxyjump'];
    jumps[alias] = jump == null || jump.toLowerCase() == 'none'
        ? []
        : jump.split(',');
  }
  List<String> route(String alias, Set<String> seen) {
    if (!seen.add(alias)) throw FormatException('$alias：跳板形成循环');
    final result = <String>[];
    for (final jump in jumps[alias] ?? <String>[]) {
      if (!candidates.containsKey(jump)) {
        throw FormatException('$alias：跳板 $jump 未定义，请手动配置后再导入');
      }
      result.addAll(route(jump, {...seen}));
      result.add(candidates[jump]!.id);
    }
    if (result.length > 8 || result.toSet().length != result.length) {
      throw FormatException('$alias：跳板路径重复或过长');
    }
    return result;
  }

  final rejected = <String>{};
  for (final entry in candidates.entries) {
    try {
      final h = entry.value;
      preview.hosts.add(
        Host(
          id: h.id,
          name: h.name,
          address: h.address,
          port: h.port,
          username: h.username,
          jumpIds: route(entry.key, {}),
        ),
      );
    } on FormatException catch (e) {
      rejected.add(entry.value.id);
      preview.warnings.add(e.message);
    }
  }
  var previous = -1;
  while (previous != rejected.length) {
    previous = rejected.length;
    for (final h in preview.hosts) {
      if (h.jumpIds.any(rejected.contains)) rejected.add(h.id);
    }
  }
  preview.hosts.removeWhere((h) => rejected.contains(h.id));
  return preview;
}

/// Explicitly supported JSON exports. Unknown/encrypted fields remain warnings.
ImportPreview parseHostJson(String source, String format) {
  final preview = ImportPreview();
  final data = jsonDecode(source);
  final records = data is List
      ? data
      : data is Map
      ? data['sessions'] ?? data['hosts']
      : null;
  if (records is! List) {
    throw const FormatException('未识别的配置结构；需要 sessions/hosts 数组');
  }
  for (final (index, item) in records.indexed) {
    if (item is! Map) {
      preview.warnings.add('第 ${index + 1} 项格式无效');
      continue;
    }
    final j = Map<String, dynamic>.from(item);
    String? string(String key) => j[key] is String ? j[key] as String : null;
    final wind = format == 'WindTerm';
    final address = wind ? string('session.target') : string('host');
    final protocol = wind ? string('session.protocol') : string('protocol');
    if (protocol != null && protocol.toLowerCase() != 'ssh') {
      preview.warnings.add('第 ${index + 1} 项协议 $protocol 需要手动配置');
      continue;
    }
    final portValue = j[wind ? 'session.port' : 'port'];
    final h = Host(
      id: Host.newId(),
      name: (wind ? string('session.name') : string('name')) ?? address ?? '',
      address: address ?? '',
      username: (wind ? string('session.user') : string('username')) ?? 'root',
      port: portValue == null ? 22 : int.tryParse('$portValue') ?? 0,
      group: (wind ? string('session.group') : string('group')) ?? '',
    );
    final known = wind
        ? {
            'session.target',
            'session.protocol',
            'session.port',
            'session.name',
            'session.user',
            'session.group',
          }
        : {'host', 'protocol', 'port', 'name', 'username', 'group'};
    final unknown = j.keys.where((k) => !known.contains(k)).toList();
    if (unknown.isNotEmpty) {
      preview.warnings.add(
        '${h.label}：未导入字段 ${unknown.join(', ')}；凭据、代理和命令需手动配置',
      );
    }
    // A source routing field must never silently become a direct connection.
    if (unknown.any(
      (k) => RegExp(
        r'proxy|jump|gateway|tunnel',
        caseSensitive: false,
      ).hasMatch(k),
    )) {
      preview.warnings.add('${h.label}：存在未支持的路由配置，整项跳过');
      continue;
    }
    try {
      h.validate();
      preview.hosts.add(h);
    } on FormatException {
      preview.warnings.add('第 ${index + 1} 项地址或端口无效');
    }
  }
  return preview;
}
