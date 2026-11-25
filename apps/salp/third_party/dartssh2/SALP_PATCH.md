# salp patch on dartssh2 4.1.0 (MIT)

Preserve SFTP path bytes: incoming SftpName retains filenameBytes/longnameBytes. Path request fields accept String (UTF-8) or Uint8List (byte exact). Added absoluteBytes and renameNoReplace; readdir closes handles when cancelled. Display strings must never be reused as remote operation paths. Other SSH functionality is upstream. Tests: apps/salp/test/sftp_bytes_test.dart plus local OpenSSH integration.

## Guarded terminal writes

`SSHChannel.writeGuarded(bytes, authorize)` waits for SSH window credit while
rechecking application authority, checks before each SSH packet, and expires
within eight seconds. Terminal input uses this path exclusively, avoiding both
the unbounded stdin stream queue and the upstream socket flush/send race. It does
not prove remote execution; completion only means packets were submitted to the
transport. Unsent bytes are not resumed after locking. Callers must not mix this
path with the unguarded channel sink. Covered by `guarded_ssh_write_test.dart`
and the real MCP→SSH terminal fixture.

## SFTP timeouts

Handshake and individual requests expire after 15 seconds (configurable through `SftpClient.requestTimeout`). Expiration closes only this SFTP channel and fails all waiting requests, including future handle cleanup; it never retries a potentially executed remote operation. This bounds stalled transfer cleanup without killing other SSH channels. Tests: `sftp_timeout_test.dart`; real 100-file batch, cancellation and retry in `ssh_integration_test.dart`.

Structured MCP channels: `SSHClient.execute` accepts an optional authorization callback before channel open and exact exec dispatch. `SSHClient.sftp` checks subsystem acceptance and forwards optional authorization to `SftpClient`, which serializes complete packets and uses guarded SSH writes across transport window waits. Invalid authorization terminates only that SFTP channel.

Request deadlines now include guarded SSH send-window waits, with reply errors observed immediately. Session channel open, exec setup and SFTP subsystem setup are bounded (20 seconds by default); abandoned open IDs are retained until a late response can safely close that channel. At most64 pending/abandoned opens prevent unbounded accumulation. Application exec/SFTP use these native deadlines rather than detached Future.timeout calls. Tested with delayed replies from real OpenSSH and a zero-window protocol fixture.
