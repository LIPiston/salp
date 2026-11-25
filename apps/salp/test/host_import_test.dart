import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host_import.dart';

void main() {
  test('OpenSSH includes expand sorted within the selected directory and reject escapes', () async {
    final dir = await Directory.systemTemp.createTemp('salp-include-');
    final outside = await Directory.systemTemp.createTemp(
      'salp-include-outside-',
    );
    try {
      await Directory('${dir.path}/conf.d').create();
      await File('${dir.path}/config')
          .writeAsString('Include conf.d/*.conf\nHost *\n User fallback\n');
      await File('${dir.path}/conf.d/20.conf')
          .writeAsString('Host target\n HostName later.test\n');
      await File(
        '${dir.path}/conf.d/10.conf',
      ).writeAsString('Host target\n HostName selected.test\n User deploy\n');
      final expanded = await parseOpenSshFile(
        File('${dir.path}/config'),
        dir,
        () {},
      );
      expect(expanded.hosts.single.address, 'selected.test');
      expect(expanded.hosts.single.username, 'deploy');
      await File('${dir.path}/config')
          .writeAsString('Host limited\n Include conf.d/*.conf\n');
      await expectLater(
        parseOpenSshFile(File('${dir.path}/config'), dir, () {}),
        throwsFormatException,
        reason: 'conditional Include must not silently become global hosts',
      );
      await File('${outside.path}/secret.conf')
          .writeAsString('Host escaped\n HostName outside.test\n');
      await Link('${dir.path}/escape.conf')
          .create('${outside.path}/secret.conf');
      await File('${dir.path}/config').writeAsString(
        'Include escape.conf\nHost protected\n HostName internal.test\n',
      );
      await expectLater(
        parseOpenSshFile(File('${dir.path}/config'), dir, () {}),
        throwsFormatException,
      );
      await File('${dir.path}/config').writeAsString('Include config\n');
      await expectLater(
        parseOpenSshFile(File('${dir.path}/config'), dir, () {}),
        throwsFormatException,
      );
      await expectLater(
        parseOpenSshFile(File('${dir.path}/config'), dir, () {
          throw StateError('locked');
        }),
        throwsStateError,
      );
    } finally {
      await dir.delete(recursive: true);
      await outside.delete(recursive: true);
    }
  });

  test('OpenSSH honors first matching values, quotes and jump aliases', () {
    final preview = parseOpenSsh('''
Host production
  HostName "internal.example"
  User deploy
  Port 2222
  ProxyJump gateway
Host gateway
  HostName bastion.example
Host *
  User fallback
  Port 22
''');
    expect(preview.hosts.length, 2);
    final prod = preview.hosts.singleWhere((h) => h.name == 'production');
    final gate = preview.hosts.singleWhere((h) => h.name == 'gateway');
    expect(prod.address, 'internal.example');
    expect(prod.port, 2222);
    expect(prod.username, 'deploy');
    expect(prod.jumpIds, [gate.id]);
    expect(gate.username, 'fallback');
    expect(gate.port, 22);
  });
  test('unsafe execution and unsupported directives are reported without executing', () {
    final result = parseOpenSsh('''
Host one
 HostName example.test
 ProxyCommand touch /tmp/never-run
 IdentityFile ~/.ssh/key
 LocalCommand echo forbidden
 Include ~/.ssh/extra
''');
    expect(result.hosts, isEmpty);
    expect(result.warnings.join('\n'), contains('ProxyCommand'));
    expect(result.warnings.join('\n'), contains('LocalCommand'));
    expect(result.warnings.join('\n'), contains('IdentityFile'));
    expect(result.warnings.join('\n'), contains('Include'));
  });
  test('unknown jumps reject the affected host instead of making a direct connection', () {
    final result = parseOpenSsh(
      'Host private\n HostName secret.test\n ProxyJump missing\nHost valid\n HostName public.test\n',
    );
    expect(result.hosts.map((h) => h.name), ['valid']);
    expect(result.warnings.join(), contains('missing'));
  });
  test('wildcards do not create invented hosts and Match is not flattened', () {
    final result = parseOpenSsh('''
Host *
 User default
Match exec "false"
 User wrong
Host node
 HostName node.test
''');
    expect(result.hosts.length, 1);
    expect(result.hosts.single.username, 'default');
    expect(result.warnings.join(), contains('Match'));
  });
  test('cyclic jump imports are rejected', () {
    final result = parseOpenSsh('Host a\n ProxyJump b\nHost b\n ProxyJump a\n');
    expect(result.hosts, isEmpty);
    expect(result.warnings, isNotEmpty);
  });
}
