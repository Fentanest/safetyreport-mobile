// 알림 기록을 백그라운드 서비스(Kotlin WsService)와 같은 설정 키에 함께 쓸 때 서로 덮지 않는지 (M-29/M-31).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _item(String id) => {
  'id': id,
  'title': id,
  'body': '',
  'reportNumber': '',
  'timestamp': '2026-09-24T12:00:00',
  'isRead': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'saving keeps items the background service added after we loaded',
    () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.notificationsHistory: jsonEncode([_item('a'), _item('b')]),
      });
      final provider = NotificationHistoryProvider();
      await provider.load(notify: false);

      // 백그라운드 서비스가 새 알림을 적음
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AppPrefsKeys.notificationsHistory,
        jsonEncode([_item('k'), _item('a'), _item('b')]),
      );

      await provider.markRead('a');
      final saved =
          (jsonDecode(prefs.getString(AppPrefsKeys.notificationsHistory)!)
                  as List)
              .map((e) => e['id'])
              .toList();
      expect(saved, containsAll(['k', 'a', 'b']));
      final a =
          (jsonDecode(prefs.getString(AppPrefsKeys.notificationsHistory)!)
                  as List)
              .firstWhere((e) => e['id'] == 'a');
      expect(a['isRead'], isTrue);
    },
  );
}
