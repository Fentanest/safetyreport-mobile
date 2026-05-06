import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/pending_changes_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PendingChangesStore', () {
    test('append accumulates changes and readAndClear consumes them', () async {
      await PendingChangesStore.append([
        {'id': 'a', 'change_type': 'new'},
      ]);
      await PendingChangesStore.append([
        {'id': 'b', 'change_type': 'changed'},
      ]);

      final stored = await PendingChangesStore.readAndClear();
      expect(stored, [
        {'id': 'a', 'change_type': 'new'},
        {'id': 'b', 'change_type': 'changed'},
      ]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppPrefsKeys.pendingCrawlChanges), isNull);
      expect(await PendingChangesStore.readAndClear(), isEmpty);
    });

    test('readAndClear returns empty list for malformed payload', () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.pendingCrawlChanges: '{not-json',
      });

      final stored = await PendingChangesStore.readAndClear();
      expect(stored, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppPrefsKeys.pendingCrawlChanges), isNull);
    });
  });

  group('ForegroundEventStore', () {
    test('readAndClear returns decoded event once', () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.foregroundEvent: jsonEncode({
          'title': 'changed',
          'payload_json': '{"id":"1"}',
        }),
      });

      final event = await ForegroundEventStore.readAndClear();
      expect(event, {'title': 'changed', 'payload_json': '{"id":"1"}'});
      expect(await ForegroundEventStore.readAndClear(), isNull);
    });
  });
}
