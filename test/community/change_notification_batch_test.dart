import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/services/pending_changes_store.dart';
import 'package:safetyreport/services/sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fentanest.mysafetyreport/permissions');

  for (final count in [20, 21, 3000]) {
    test('$count건 변경 시 OS 알림 수를 제한하고 변경 목록은 보존한다', () async {
      SharedPreferences.setMockInitialValues({});
      final calls = <MethodCall>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final changes = List.generate(count, (i) => <String, dynamic>{
            'notification_kind': 'report',
            'change_type': ChangeType.statusChanged,
            '신고번호': 'R$i',
          });
      await SyncEngine.emitChanges(changes);

      final notifications = calls.where((call) => call.method == 'showNotification').toList();
      expect(notifications.length, count <= 20 ? count : 1);
      if (count > 20) {
        final args = Map<String, dynamic>.from(notifications.single.arguments as Map);
        expect(args['body'], '$count건의 변경사항이 있습니다');
        expect(args.containsKey('payload_json'), isFalse);
      }
      expect((await PendingChangesStore.readAndClear()).length, count);
    });
  }
}
