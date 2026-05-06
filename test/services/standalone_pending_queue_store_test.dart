import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
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
  });
}
