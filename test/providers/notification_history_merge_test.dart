// 알림 기록: 백그라운드 서비스(Kotlin WsService)는 수신함 키에만 넣고 앱이 합친다 (M-29/M-31, R6).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/prefs_inbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _item(String id) => {
  'id': id,
  'title': id,
  'body': '',
  'reportNumber': '',
  'timestamp': '2026-09-24T12:00:00',
  'isRead': false,
};

/// WsService.putInbox 와 같은 모양의 키.
String _serviceKey(int ms, int seq) =>
    '${PrefsInbox.history}${ms.toString().padLeft(15, '0')}_${seq.toString().padLeft(6, '0')}';

Future<List<String>> _savedIds() async {
  final prefs = await SharedPreferences.getInstance();
  return (jsonDecode(prefs.getString(AppPrefsKeys.notificationsHistory)!)
          as List)
      .map((e) => e['id'] as String)
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'items the service put in the inbox are merged newest first and the inbox is emptied',
    () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.notificationsHistory: jsonEncode([_item('a')]),
        _serviceKey(1000, 1): jsonEncode([_item('k2'), _item('k1')]),
        _serviceKey(2000, 2): jsonEncode([_item('m')]),
      });
      final provider = NotificationHistoryProvider();
      await provider.load(notify: false);
      expect(provider.items.map((i) => i.id), ['m', 'k2', 'k1', 'a']);
      expect(await _savedIds(), ['m', 'k2', 'k1', 'a']);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((k) => k.startsWith(PrefsInbox.history)),
        isEmpty,
      );
    },
  );

  test(
    'saving keeps items the service added after we loaded and does not bring back cleared ones',
    () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.notificationsHistory: jsonEncode([_item('a'), _item('b')]),
      });
      final provider = NotificationHistoryProvider();
      await provider.load(notify: false);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_serviceKey(3000, 3), jsonEncode([_item('k')]));
      await provider.markRead('a');
      expect(await _savedIds(), ['k', 'a', 'b']);
      expect(provider.items.firstWhere((i) => i.id == 'a').isRead, isTrue);

      await provider.clearAll();
      await provider.load(notify: false);
      expect(provider.items, isEmpty);
    },
  );
}
