import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/pending_changes_store.dart';
import 'package:safetyreport/services/prefs_inbox.dart';
import 'package:safetyreport/services/standalone_pending_queue_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fentanest.mysafetyreport/permissions');
  setUp(() => PrefsInbox.useNativeBridgeForTest = true);
  tearDown(() {
    PrefsInbox.useNativeBridgeForTest = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  for (final prefix in [PrefsInbox.queue, PrefsInbox.pending]) {
    test(
      '$prefix consumes only claimed scope and retains legacy scalar',
      () async {
        final scalar = prefix == PrefsInbox.queue
            ? AppPrefsKeys.standalonePendingReports
            : AppPrefsKeys.pendingCrawlChanges;
        final oldValue = prefix == PrefsInbox.queue
            ? 'old-report'
            : jsonEncode([
                {'report_number': 'old-report'},
              ]);
        final newValue = prefix == PrefsInbox.queue
            ? 'new-report'
            : jsonEncode([
                {'report_number': 'new-report'},
              ]);
        final newKey = '${prefix}native.notification.new';
        final oldKey = '${prefix}native.notification.old';
        SharedPreferences.setMockInitialValues({
          scalar: oldValue,
          oldKey: oldValue,
        });
        final prefs = await SharedPreferences.getInstance();
        final acks = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'processingInboxRead') {
                return {
                  'pending': [
                    {'key': newKey, 'value': newValue},
                  ],
                  'acknowledged': [oldKey],
                  'migrated': [],
                  'blockedScope': 1,
                  'blockedLegacy': 1,
                };
              }
              acks.addAll(
                ((call.arguments as Map)['keys'] as List).cast<String>(),
              );
              return true;
            });
        if (prefix == PrefsInbox.queue) {
          await PrefsInbox.synchronize(prefs, prefix);
          expect(StandalonePendingQueueStore.read(prefs), ['new-report']);
          await StandalonePendingQueueStore.acknowledge(
            prefs,
            StandalonePendingQueueStore.claim(prefs)!,
          );
        } else {
          final claim = await PendingChangesStore.readPending();
          expect(claim.items, [
            {'report_number': 'new-report'},
          ]);
          await PendingChangesStore.acknowledge(claim);
        }
        await prefs.reload();
        expect(acks, [newKey]);
        expect(prefs.getString(scalar), oldValue);
        expect(prefs.containsKey(newKey), isFalse);
        expect(PrefsInbox.isReadableKey(oldKey, prefix), isFalse);
      },
    );
  }
}
