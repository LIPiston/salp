import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:salp/core/android_documents.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'SAF streams, conflict preservation, cancellation and process death cleanup',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('SAF fixture'))),
        ),
      );
      final directory = await getApplicationSupportDirectory();
      const run = String.fromEnvironment(
        'SALP_SAF_RUN',
        defaultValue: 'manual',
      );
      final phase = File('${directory.path}/saf-journal-fixture-$run');
      if (await phase.exists()) {
        final target = await phase.readAsString();
        final recovery = await AndroidDocuments.recoveryStatus();
        expect(recovery['recovered'], 1);
        expect(recovery['pending'], 0);
        // Reusing this exact name succeeds only if startup recovered the partial
        // document; otherwise the bridge returns its conflict error.
        final id = await AndroidDocuments.create(target, 'interrupted.bin');
        await AndroidDocuments.abort(id);
        await phase.delete();
        debugPrint('SALP_SAF_RECOVERY_PASSED');
        return;
      }
      debugPrint('SALP_SAF_PICK_DIRECTORY');
      final target = await AndroidDocuments.chooseDirectory();
      expect(target, startsWith('content://'));
      final data = Uint8List.fromList(List.generate(150000, (i) => i % 251));
      final complete = await AndroidDocuments.create(target!, 'complete.bin');
      await AndroidDocuments.write(complete, data);
      await AndroidDocuments.finish(complete);
      await expectLater(
        AndroidDocuments.create(target, 'complete.bin'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      final aborted = await AndroidDocuments.create(target, 'aborted.bin');
      await AndroidDocuments.write(aborted, Uint8List.fromList([1, 2, 3]));
      await AndroidDocuments.abort(aborted);
      final keep = await AndroidDocuments.create(
        target,
        'complete.bin',
        keepBoth: true,
      );
      await AndroidDocuments.write(keep, Uint8List.fromList([9, 8, 7]));
      await AndroidDocuments.finish(keep);
      // A competing writer wins the final name while our temporary is open.
      final competitor = await AndroidDocuments.create(target, 'contended.bin');
      final loser = await AndroidDocuments.create(target, 'contended.bin');
      await AndroidDocuments.write(competitor, Uint8List.fromList([42]));
      await AndroidDocuments.finish(competitor);
      await expectLater(
        AndroidDocuments.finish(loser),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      await AndroidDocuments.abort(loser);
      final interrupted = await AndroidDocuments.create(
        target,
        'interrupted.bin',
      );
      await AndroidDocuments.write(interrupted, Uint8List.fromList([1, 2, 3]));
      await phase.writeAsString(target, flush: true);
      debugPrint('SALP_SAF_READY_TO_KILL');
      // The controller force-stops this process before normal activity cleanup.
      await Future<void>.delayed(const Duration(minutes: 3));
      fail('Controller did not force-stop fixture');
    },
  );
}
