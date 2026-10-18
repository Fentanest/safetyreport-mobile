import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 앱에서 읽은 신고·중복군의 시스템 알림을 지운다(2026-10-18).
///
/// 변경 알림은 Kotlin 이 신고번호·중복군 ID 별 태그로 띄운다(`NativeNotifications.changeTag`).
/// 상세 시트·알림 기록·푸시 탭 어느 경로로 읽든 [NotificationHistoryProvider] 가 이 함수를 불러 같은 신고의
/// 푸시를 함께 지운다. [all] 이면 앱이 띄운 결과·변경 알림 전부(모든 기록을 읽었을 때).
class SystemNotifications {
  SystemNotifications._();

  static const MethodChannel _channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  /// 시험이 바꿔 끼운다. 기본은 MainActivity `cancelChangeNotifications`.
  @visibleForTesting
  static Future<void> Function(Map<String, Object?> args) invoker = _invoke;

  static Future<void> _invoke(Map<String, Object?> args) =>
      _channel.invokeMethod<Object?>('cancelChangeNotifications', args);

  static Future<void> cancelRead({
    Iterable<String> reportNumbers = const [],
    Iterable<String> groupIds = const [],
    bool all = false,
  }) async {
    final reports = {
      for (final n in reportNumbers)
        if (n.trim().isNotEmpty) n.trim().toUpperCase(),
    }.toList();
    final groups = {
      for (final g in groupIds)
        if (g.trim().isNotEmpty) g.trim(),
    }.toList();
    if (reports.isEmpty && groups.isEmpty && !all) return;
    try {
      await invoker({
        'report_numbers': reports,
        'group_ids': groups,
        'all': all,
      });
    } catch (_) {
      // 구버전 네이티브·시험 환경(MissingPluginException) — 시스템 알림은 기존처럼 탭할 때만 사라진다.
    }
  }
}
