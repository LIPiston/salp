import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:dart_mosh/dart_mosh.dart';

import 'telnet_codec.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'host.dart';
import 'host_keys.dart';
import 'input_gate.dart';
import 'repository.dart';
import 'tunnels.dart';
import 'session_log.dart';
import 'ssh_agent.dart';
import 'serial.dart';
import 'highlight.dart';

typedef VerifyHost = Future<bool> Function(
  Host host,
  String algorithm,
  String fingerprint,
  String? previous,
);
typedef PromptAuth = Future<List<String>?> Function(SSHUserInfoRequest request);

class TrustSaved implements Exception {
  @override
  String toString() => '主机密钥已保存，请再次点击连接';
}

class SshConnection {
  SshConnection(this.clients);
  final List<SSHClient> clients;
  SSHClient get client => clients.last;
  static Future<SshConnection> connect(
    Repository repo,
    Host target,
    VerifyHost verify,
    PromptAuth prompt,
  ) async {
    final authority = repo.epoch;
    repo.checkAuthority(authority);
    target.validate();
    final route = [...target.jumpIds.map(repo.host), target];
    final clients = <SSHClient>[];
    try {
      for (final host in route) {
        repo.checkAuthority(authority);
        final credential = repo.credentials[host.id] ?? const Credential();
        final identities = credential.useAgent
            ? await DesktopSshAgent(
                Platform.environment['SSH_AUTH_SOCK'] ?? '',
                () => repo.checkAuthority(authority),
              ).identities()
            : credential.privateKey.isEmpty
            ? null
            : SSHKeyPair.fromPem(
                credential.privateKey,
                credential.passphrase.isEmpty ? null : credential.passphrase,
              );
        repo.checkAuthority(authority);
        final socket = clients.isEmpty
            ? await SSHSocket.connect(
                host.address,
                host.port,
                timeout: const Duration(seconds: 15),
              )
            : await clients.last.forwardLocal(host.address, host.port);
        try {
          repo.checkAuthority(authority);
        } catch (_) {
          socket.destroy();
          rethrow;
        }
        var saved = false;
        final client = SSHClient(
          socket,
          username: host.username,
          identities: identities,
          handshakeTimeout: const Duration(seconds: 20),
          authTimeout: const Duration(minutes: 2),
          onPasswordRequest: () {
            repo.checkAuthority(authority);
            return credential.password;
          },
          onUserInfoRequest: (request) async {
            repo.checkAuthority(authority);
            final result = await prompt(request);
            repo.checkAuthority(authority);
            return result;
          },
          onVerifyHostKey: (algorithm, bytes) async {
            repo.checkAuthority(authority);
            final fingerprint = utf8.decode(bytes);
            final policy = HostKeyPolicy(repo.knownHosts);
            if (policy.matches(host.endpoint, algorithm, fingerprint)) {
              return true;
            }
            if (await verify(
              host,
              algorithm,
              fingerprint,
              repo.knownHosts[host.endpoint],
            )) {
              repo.checkAuthority(authority);
              await repo.update((draft) {
                HostKeyPolicy(draft.knownHosts)
                    .pin(host.endpoint, algorithm, fingerprint);
              }, authority: authority);
              saved = true;
            }
            return false;
          },
        );
        clients.add(client);
        try {
          await client.authenticated;
          repo.checkAuthority(authority);
        } catch (_) {
          if (saved) throw TrustSaved();
          rethrow;
        }
      }
      return SshConnection(clients);
    } catch (_) {
      for (final client in clients.reversed) {
        client.close();
      }
      rethrow;
    }
  }

  Future<void> close() async {
    for (final client in clients.reversed) {
      client.close();
    }
    await Future.wait(clients.map((c) => c.done))
        .timeout(const Duration(seconds: 5));
  }
}

class TerminalSession extends ChangeNotifier {
  TerminalSession(this.title, {this.host}) {
    input = InputGate.guarded((bytes, authorize) async {
      final writer = _write;
      if (writer == null) throw StateError('会话尚未连接');
      await writer(bytes, authorize);
    });
    terminal.onOutput = (text) {
      if (!input.locked && !closed) unawaited(send(text));
    };
    terminal.onResize = (columns, rows, pw, ph) {
      if (!input.locked && !closed) _resize?.call(columns, rows);
    };
  }
  final String title;
  final Host? host;
  final terminal = Terminal(maxLines: 10000);
  late final InputGate input;
  final tunnels = <Tunnel>[];
  int interactionEpoch = 0;
  String status = '连接中';
  String? error;
  bool connected = false, closed = false;
  SshConnection? ssh;
  SSHSession? shell;
  Future<void> Function(Uint8List, void Function())? _write;
  void Function(int, int)? _resize;
  void Function()? _discardUnsent;
  Future<void> Function()? _close;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _hidden = StringBuffer();
  int _hiddenLength = 0;
  bool _hiddenOverflow = false;
  SessionLog? log;
  TerminalHighlighter? highlighter;
  void configureHighlight(Repository repo) {
    final override = host == null ? null : repo.hostHighlight[host!.id];
    final enabled = override == null
        ? repo.highlightEnabled
        : override['enabled'] == true;
    final source = override == null
        ? repo.highlightRules
        : (override['rules'] as List).map(
            (r) => Map<String, dynamic>.from(r as Map),
          );
    final rules = enabled
        ? source.map(HighlightRule.fromJson).toList()
        : <HighlightRule>[];
    if (highlighter == null) {
      highlighter = TerminalHighlighter(terminal, rules);
    } else {
      highlighter!.update(rules);
    }
  }

  Future<void> startLog(Repository repo) async {
    final authority = repo.epoch;
    repo.checkAuthority(authority);
    final opened = await SessionLog.start(
      Directory('${repo.directory.path}/logs'),
      repo.key,
    );
    if (closed || input.locked || repo.locked || repo.epoch != authority) {
      await opened.close();
      return;
    }
    log = opened;
    notifyListeners();
  }

  Future<void> stopLog() async {
    final previous = log;
    log = null;
    await previous?.close();
    notifyListeners();
  }

  void _output(String text) {
    try {
      if (log != null && !log!.append(text)) {
        error = '日志达到大小上限，已停止记录';
        unawaited(stopLog());
      }
    } catch (_) {
      error = '日志写入失败，终端连接保留';
      unawaited(stopLog());
    }
    if (input.locked) {
      if (_hiddenLength + text.length <= 1024 * 1024) {
        _hidden.write(text);
        _hiddenLength += text.length;
      } else {
        _hiddenOverflow = true;
      }
    } else {
      terminal.write(text);
    }
  }

  void _listen(Stream<List<int>> stream) {
    _subscriptions.add(
      stream
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            _output,
            onError: (Object _) {
              error = '连接读取失败';
              notifyListeners();
            },
          ),
    );
  }

  Future<void> send(String text) async {
    interactionEpoch++;
    try {
      await input.send(Uint8List.fromList(utf8.encode(text)), input.generation);
    } catch (_) {
      error = '输入未接受或状态未知，请检查终端后重新输入';
      notifyListeners();
    }
  }

  void setLocked(bool value) {
    if (value) {
      input.lock();
      _discardUnsent?.call();
    } else {
      terminal.write(_hidden.toString());
      _hidden.clear();
      _hiddenLength = 0;
      if (_hiddenOverflow) {
        terminal.write('\r\n[锁定期间输出超过缓冲上限]\r\n');
        _hiddenOverflow = false;
      }
      input.unlock();
    }
    notifyListeners();
  }

  void _checkOpening(int generation) {
    if (closed || input.locked || input.generation != generation) {
      throw StateError('连接上下文已失效，请重新连接');
    }
  }

  Future<void> openSsh(
    Repository repo,
    VerifyHost verify,
    PromptAuth prompt,
  ) async {
    final generation = input.generation;
    final authority = repo.epoch;
    try {
      _checkOpening(generation);
      repo.checkAuthority(authority);
      ssh = await SshConnection.connect(repo, host!, verify, prompt);
      repo.checkAuthority(authority);
      _checkOpening(generation);
      if (closed) {
        await ssh!.close();
        return;
      }
      shell = await ssh!.client.shell(
        pty: SSHPtyConfig(
          width: terminal.viewWidth,
          height: terminal.viewHeight,
        ),
      );
      repo.checkAuthority(authority);
      _checkOpening(generation);
      _write = (bytes, authorize) =>
          shell!.channel.writeGuarded(bytes, authorize);
      _resize = (c, r) => shell!.resizeTerminal(c, r);
      _close = () async {
        shell!.close();
        await ssh!.close();
      };
      _listen(shell!.stdout);
      _listen(shell!.stderr);
      unawaited(
        shell!.done.then((_) {
          connected = false;
          status = '已断开';
          notifyListeners();
        }),
      );
      connected = true;
      status = '已连接';
    } catch (e) {
      await ssh?.close();
      status = '连接失败';
      error = e is TrustSaved ? e.toString() : '连接失败，请检查地址、凭据或主机密钥';
    }
    notifyListeners();
  }

  Future<void> openTelnet() async {
    final generation = input.generation;
    Socket? openingSocket;
    try {
      _checkOpening(generation);
      final socket = openingSocket = await Socket.connect(
        host!.address,
        host!.port,
        timeout: const Duration(seconds: 15),
      );
      if (closed) {
        socket.destroy();
        return;
      }
      _checkOpening(generation);
      final codec = TelnetCodec((bytes) {
        if (!input.locked && !closed) socket.add(bytes);
      });
      _write = (bytes, authorize) async {
        authorize();
        socket.add(bytes.expand((b) => b == 255 ? [255, 255] : [b]).toList());
        await socket.flush();
      };
      _close = () async {
        socket.destroy();
      };
      _listen(socket.map(codec.decode));
      connected = true;
      status = 'Telnet · 未加密';
    } catch (_) {
      openingSocket?.destroy();
      status = '连接失败';
      error = 'Telnet 连接失败';
    }
    notifyListeners();
  }

  Future<void> openMosh(
    Repository repo,
    VerifyHost verify,
    PromptAuth prompt,
  ) async {
    final generation = input.generation;
    final authority = repo.epoch;
    try {
      _checkOpening(generation);
      repo.checkAuthority(authority);
      ssh = await SshConnection.connect(repo, host!, verify, prompt);
      repo.checkAuthority(authority);
      _checkOpening(generation);
      final response = await ssh!.client.run(
        const MoshSshBootstrap(locale: 'C.UTF-8').command(),
      );
      repo.checkAuthority(authority);
      _checkOpening(generation);
      final config = MoshServerConfig.parse(
        utf8.decode(response),
        host: host!.address,
      );
      final mosh = await MoshSession.connect(
        server: config,
        cipher: MoshPacketCipher.aesOcb(config.key),
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      if (closed ||
          input.locked ||
          input.generation != generation ||
          repo.locked ||
          repo.epoch != authority) {
        await mosh.close();
        await ssh!.close();
        return;
      }
      _write = (bytes, authorize) async {
        authorize();
        mosh.send(bytes, authorize: authorize);
      };
      _discardUnsent = mosh.discardUnsent;
      _resize = (c, r) => mosh.resize(c, r);
      _close = () async {
        await mosh.close();
        await ssh!.close();
      };
      _listen(mosh.stdout);
      _subscriptions.add(
        mosh.errors.listen((_) {
          error = 'Mosh 网络异常；可关闭后选择 SSH 重连';
          notifyListeners();
        }),
      );
      unawaited(
        mosh.done.then((_) {
          connected = false;
          status = '已断开';
          notifyListeners();
        }),
      );
      connected = true;
      status = 'Mosh · 已连接';
    } catch (e) {
      status = '连接失败';
      error = e is TrustSaved
          ? e.toString()
          : 'Mosh 启动失败，请确认服务器安装 mosh-server、UDP 可达，或手动选择 SSH';
      await ssh?.close();
    }
    notifyListeners();
  }

  Future<void> openSerial(
    String path, {
    int baud = 115200,
    int bits = 8,
    int stopBits = 1,
    int parity = 0,
    int flow = 0,
  }) async {
    try {
      _checkOpening(input.generation);
      final serial = SerialConnection.open(
        path,
        baud: baud,
        bits: bits,
        stopBits: stopBits,
        parity: parity,
        flowControl: flow,
      );
      _write = (bytes, authorize) => serial.write(bytes, authorize: authorize);
      _close = serial.close;
      _listen(serial.output);
      connected = true;
      status = '串口 · $baud · $bits/$stopBits';
    } catch (e) {
      status = '连接失败';
      error = e is SerialException || e is FormatException
          ? e.toString()
          : '无法打开串口';
    }
    notifyListeners();
  }

  Future<void> openLocal() async {
    try {
      _checkOpening(input.generation);
      if (Platform.isAndroid) throw UnsupportedError('Android 不提供本地 shell');
      final pty = Pty.start(
        Platform.isWindows
            ? 'powershell.exe'
            : (Platform.environment['SHELL'] ?? '/bin/sh'),
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      _write = (bytes, authorize) async {
        authorize();
        pty.write(bytes);
      };
      _resize = (c, r) => pty.resize(r, c);
      _close = () async {
        pty.kill();
        await pty.exitCode.timeout(const Duration(seconds: 5));
      };
      _listen(pty.output);
      unawaited(
        pty.exitCode.then((_) {
          connected = false;
          status = '已退出';
          notifyListeners();
        }),
      );
      connected = true;
      status = '已连接';
    } catch (_) {
      status = '启动失败';
      error = '无法打开本地终端';
    }
    notifyListeners();
  }

  Future<void> close() async {
    closed = true;
    input.close();
    highlighter?.dispose();
    await stopLog();
    for (final tunnel in tunnels.where((t) => t.active)) {
      await tunnel.close();
    }
    await _close?.call();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    connected = false;
    status = '已关闭';
    notifyListeners();
  }
}
