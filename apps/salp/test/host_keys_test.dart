import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/host_keys.dart';

void main() {
  test('trust binds endpoint, algorithm and exact fingerprint', () {
    final keys = HostKeyPolicy({});
    expect(keys.matches('[server]:22', 'ssh-ed25519', 'SHA256:one'), false);
    keys.pin('[server]:22', 'ssh-ed25519', 'SHA256:one');
    expect(keys.matches('[server]:22', 'ssh-ed25519', 'SHA256:one'), true);
    expect(keys.matches('[server]:22', 'ssh-ed25519', 'SHA256:two'), false);
    expect(keys.matches('[server]:2222', 'ssh-ed25519', 'SHA256:one'), false);
    expect(keys.matches('[server]:22', 'ssh-rsa', 'SHA256:one'), false);
  });
}
