import 'package:flutter_test/flutter_test.dart';
import 'package:salp/core/master_password.dart';

void main() {
  test(
    'master password verifier rejects wrong passwords and uses salted hashes',
    () async {
      final record = await MasterPassword.create('correct horse battery');
      expect(
        record.values.any((v) => v.contains('correct horse battery')),
        false,
      );
      expect(
        await MasterPassword.verify('correct horse battery', record),
        true,
      );
      expect(await MasterPassword.verify('wrong', record), false);
      expect(
        (await MasterPassword.create('correct horse battery'))['salt'],
        isNot(record['salt']),
      );
    },
  );
}
