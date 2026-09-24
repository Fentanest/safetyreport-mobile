import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/prefs_inbox.dart';
import 'package:safetyreport/services/standalone_pending_queue_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('StandalonePendingQueueStore', () {
    test('append deduplicates while preserving first-seen order', () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.standalonePendingReports: 'A,B',
      });

      await StandalonePendingQueueStore.append(['B', 'C', 'A']);

      final prefs = await SharedPreferences.getInstance();
      expect(StandalonePendingQueueStore.read(prefs), ['A', 'B', 'C']);
    });

    test('remove deletes a single queue item', () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.standalonePendingReports: 'A,B,C',
      });

      final prefs = await SharedPreferences.getInstance();
      await StandalonePendingQueueStore.remove(prefs, 'B');

      expect(StandalonePendingQueueStore.read(prefs), ['A', 'C']);
    });

    test(
      'items the service put in the inbox are queued in order and removal keeps the others (G11-5)',
      () async {
        String key(int ms, int seq) =>
            '${PrefsInbox.queue}${ms.toString().padLeft(15, '0')}_${seq.toString().padLeft(6, '0')}';
        SharedPreferences.setMockInitialValues({
          AppPrefsKeys.standalonePendingReports: 'A',
          key(2000, 2): 'C',
          key(1000, 1): 'B',
          key(3000, 3): 'B',
        });
        final prefs = await SharedPreferences.getInstance();
        expect(StandalonePendingQueueStore.read(prefs), ['A', 'B', 'C']);

        await StandalonePendingQueueStore.append(['D']);
        await StandalonePendingQueueStore.remove(prefs, 'B');
        expect(StandalonePendingQueueStore.read(prefs), ['A', 'C', 'D']);
        await StandalonePendingQueueStore.remove(prefs, 'A');
        expect(prefs.getString(AppPrefsKeys.standalonePendingReports), isNull);
        expect(StandalonePendingQueueStore.read(prefs), ['C', 'D']);
      },
    );
  });
}
