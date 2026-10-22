// 사용자 조치 알림(CLIENT-RULES 8절). 사용자가 해야 할 일이 있을 때만, 사유별로 하루 1번 알린다.
//
// - 알림: 앱에 이미 있는 채널(`com.fentanest.mysafetyreport/permissions` 의 `showNotification`)과 알림 권한 확인
//   (`PermissionService.isNotificationPermissionGranted`)을 그대로 쓴다. 새 채널·권한 요청을 만들지 않는다.
//   WorkManager 백그라운드 엔진에는 그 채널이 없으므로 [UserActionNotifier.prefsAlert] 키로 Kotlin 에 넘긴다.
// - 권한이 없으면 알림은 보내지 않고, 앱 안 안내(UserActionBanner)가 읽을 상태만 남긴다.
// - 사유별 마지막 알림 날짜(기기 KST)와 현재 안내 목록은 SharedPreferences 에 둔다(백그라운드 isolate 와 공유).
// - 점검(maintenance)은 사용자가 할 일이 없으므로 여기 오지 않는다(배너만, B).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/permission_service.dart';
import '../report/report_env.dart';

/// 알림·안내 한 건. [reason] 은 진행 보고의 사유 코드와 같다.
@immutable
class UserActionItem {
  const UserActionItem(this.reason, {this.count});

  final String reason;
  final int? count;

  /// 알림 문구와 같은 안내 문장(앱 안 안내도 같은 문장, 8절 표).
  String get notificationText =>
      UserActionNotifier.notificationText(reason, count: count);

  Map<String, Object?> toJson() => {'reason': reason, 'count': count};

  @override
  bool operator ==(Object other) =>
      other is UserActionItem && other.reason == reason && other.count == count;
  @override
  int get hashCode => Object.hash(reason, count);
}

class UserActionNotifier {
  UserActionNotifier._();

  static const reasonOfficialLogin = 'official_login_required';
  static const reasonOptimizeBlocked = 'optimize_blocked_background';
  static const reasonStaleHolds = 'stale_holds';
  static const reasonUpdateRequired = 'update_required';
  static const reasons = [
    reasonUpdateRequired,
    reasonOfficialLogin,
    reasonStaleHolds,
    reasonOptimizeBlocked,
  ];

  static const prefsItems = 'user_action.items';
  static String prefsLastDay(String reason) => 'user_action.last_day.$reason';

  /// 알림을 누르면 Kotlin 이 `nav_event_type` 으로 돌려주는 값 접두사. B 가 `_handleNavigationEvent` 에서 받는다.
  static const eventPrefix = 'user_action_';
  static String eventType(String reason) => '$eventPrefix$reason';

  /// 앱 안 안내 목록(포그라운드에서 갱신). 위젯은 이것을 듣는다.
  static final ValueNotifier<List<UserActionItem>> items = ValueNotifier(
    const [],
  );

  @visibleForTesting
  static Future<bool> Function() permissionGranted =
      PermissionService.isNotificationPermissionGranted;

  @visibleForTesting
  static Future<void> Function(Map<String, Object?> args) show = _show;

  static const MethodChannel _channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  /// WorkManager 백그라운드 엔진에는 위 채널이 없다(MainActivity·알림 엔진에만 등록). 그때는 이 키에 알림 내용을 쓰고,
  /// Kotlin `SafetyReportApplication` 이 키 변경을 듣고 같은 채널(`app_push_v2`)로 띄운다(R1-6). 이름을 바꾸면 Kotlin 도 같이.
  static const prefsAlert = 'user_action_alert';

  static Future<void> _show(Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<Object?>('showNotification', args);
    } on MissingPluginException {
      await _showViaPrefs(args);
    }
  }

  /// 백그라운드 엔진의 알림: 내용과 시각을 저장해 같은 프로세스의 Kotlin 리스너가 띄우게 한다(값이 바뀌어야 리스너가 불린다).
  @visibleForTesting
  static Future<void> showViaPrefsForTest(Map<String, Object?> args) =>
      _showViaPrefs(args);

  static Future<void> _showViaPrefs(Map<String, Object?> args) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      prefsAlert,
      jsonEncode({...args, 'at': ReportEnv.now().millisecondsSinceEpoch}),
    );
    if (!saved) throw StateError('user_action_alert_not_saved');
  }

  static String notificationText(String reason, {int? count}) =>
      switch (reason) {
        reasonOfficialLogin => '안전신문고 로그인이 필요합니다. 앱에서 다시 로그인해 주세요.',
        reasonOptimizeBlocked => '신고 공유를 이어 가려면 앱을 한 번 열어 주세요.',
        reasonStaleHolds =>
          '30일 넘게 올리지 못한 신고가 ${count ?? 0}건 있습니다. 앱에서 확인해 주세요.',
        reasonUpdateRequired => '앱을 업데이트해 주세요. 업데이트하면 신고 공유를 이어 갑니다.',
        _ => '',
      };

  /// 지금 조치가 필요한 사유를 모아 앱 안 안내 상태를 갱신하고, 오늘 아직 알리지 않은 사유만 알린다.
  /// 아무것도 던지지 않는다.
  static Future<void> evaluate({
    required String? backfillReason,
    required bool officialLoginManual,
    required bool optimizeBlockedInBackground,
    required int staleHolds,
    required bool updateRequired,
  }) async {
    try {
      await _evaluate(
        backfillReason: backfillReason,
        officialLoginManual: officialLoginManual,
        optimizeBlockedInBackground: optimizeBlockedInBackground,
        staleHolds: staleHolds,
        updateRequired: updateRequired,
      );
    } catch (_) {}
  }

  static Future<void> _evaluate({
    required String? backfillReason,
    required bool officialLoginManual,
    required bool optimizeBlockedInBackground,
    required int staleHolds,
    required bool updateRequired,
  }) async {
    final active = <UserActionItem>[
      if (updateRequired) const UserActionItem(reasonUpdateRequired),
      if (backfillReason == reasonOfficialLogin && officialLoginManual)
        const UserActionItem(reasonOfficialLogin),
      if (staleHolds > 0) UserActionItem(reasonStaleHolds, count: staleHolds),
      if (optimizeBlockedInBackground)
        const UserActionItem(reasonOptimizeBlocked),
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.setString(
      prefsItems,
      jsonEncode([for (final i in active) i.toJson()]),
    );
    if (!listEquals(items.value, active)) items.value = active;
    if (active.isEmpty) return;

    final today = ReportEnv.kstDate(ReportEnv.now());
    final due = [
      for (final i in active)
        if (prefs.getString(prefsLastDay(i.reason)) != today) i,
    ];
    if (due.isEmpty) return;
    // 권한이 없으면 알림 없이 앱 안 안내만(위에서 이미 저장). 권한을 새로 요청하지 않는다.
    if (!await permissionGranted()) return;
    for (final i in due) {
      try {
        await show({
          'title': '나만의 안전신문고',
          'body': i.notificationText,
          'nav_tab': 0,
          'event_type': eventType(i.reason),
        });
        await prefs.setString(prefsLastDay(i.reason), today);
      } catch (_) {
        // 알림 채널이 없거나 실패하면 오늘 알린 것으로 치지 않는다(앱 안 안내는 그대로).
      }
    }
  }

  /// 저장된 안내 목록을 읽어 [items] 에 반영한다(앱 시작·백그라운드 실행 뒤 화면 진입 때).
  static Future<List<UserActionItem>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(prefsItems);
      final out = <UserActionItem>[];
      if (raw != null) {
        final d = jsonDecode(raw);
        if (d is List) {
          for (final e in d) {
            if (e is Map && reasons.contains(e['reason'])) {
              final c = e['count'];
              out.add(
                UserActionItem(
                  e['reason'] as String,
                  count: c is int ? c : null,
                ),
              );
            }
          }
        }
      }
      if (!listEquals(items.value, out)) items.value = out;
      return out;
    } catch (_) {
      return items.value;
    }
  }

  /// 조치가 끝났을 때(로그인 성공 등) 바로 안내를 지운다. 다음 [evaluate] 가 다시 채운다.
  static Future<void> clear() async {
    items.value = const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsItems);
    } catch (_) {}
  }
}
