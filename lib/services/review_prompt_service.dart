import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/report.dart';
import 'app_prefs_keys.dart';

/// Play 스토어 별점 요청(구글 앱 내 리뷰).
///
/// 구글 API 는 사용자가 별점을 줬는지, 창이 떴는지조차 알려 주지 않는다(의도된 설계).
/// 그래서 "우리가 몇 번·언제 요청했는지"로만 조절한다: 설치 7일·사용한 날 5일 이상,
/// 90일에 한 번, 평생 3번까지. 요청 시점은 "최근 3일 안에 받은 좋은 결과(수용·과태료 등)를
/// 보고 상세 시트를 닫은 직후"이며, 이번 실행에서 오류가 있었으면 요청하지 않는다.
/// 요청 전에 만족도를 묻고 만족한 사람에게만 띄우는 방식은 구글 정책 위반이라 쓰지 않는다.
class ReviewPromptService {
  static const minInstallAge = Duration(days: 7);
  static const minActiveDays = 5;
  static const minInterval = Duration(days: 90);
  static const maxRequests = 3;
  static const freshAnswerWindow = Duration(days: 3);

  static bool _sessionHadError = false;

  @visibleForTesting
  static ReviewApi api = _InAppReviewApi();

  /// 동기화 실패·로그인 실패·목록 로드 실패 등. 이번 실행에서는 요청하지 않는다.
  static void markSessionError() => _sessionHadError = true;

  @visibleForTesting
  static void resetSession() => _sessionHadError = false;

  static String _dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// 앱 시작·복귀 때 호출. 설치 시점과 사용한 날 수를 센다.
  static Future<void> recordAppOpen({DateTime? now}) async {
    final t = now ?? DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(AppPrefsKeys.reviewFirstOpenAt) == null) {
      await prefs.setInt(
        AppPrefsKeys.reviewFirstOpenAt,
        t.millisecondsSinceEpoch,
      );
    }
    final today = _dayKey(t);
    if (prefs.getString(AppPrefsKeys.reviewLastActiveDay) != today) {
      await prefs.setString(AppPrefsKeys.reviewLastActiveDay, today);
      await prefs.setInt(
        AppPrefsKeys.reviewActiveDays,
        (prefs.getInt(AppPrefsKeys.reviewActiveDays) ?? 0) + 1,
      );
    }
  }

  /// 좋은 결과: 수용·일부수용이거나 과태료·범칙금 처분.
  static bool isPositiveOutcome(Report r) {
    final status = r.status.trim();
    if (status == '수용' || status == '일부수용') return true;
    return r.fineInfo.contains('과태료') || r.fineInfo.contains('범칙금');
  }

  static bool isFresh(Report r, DateTime now) {
    final at = r.syncedAt;
    if (at == null) return false;
    return now.millisecondsSinceEpoch - at <= freshAnswerWindow.inMilliseconds;
  }

  /// 신고 상세 시트를 닫은 뒤 호출. 요청했으면 true.
  static Future<bool> maybeRequestAfterViewing(
    Report report, {
    required bool isDemo,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    if (isDemo || _sessionHadError) return false;
    if (!isPositiveOutcome(report) || !isFresh(report, t)) return false;

    final prefs = await SharedPreferences.getInstance();
    final firstOpen = prefs.getInt(AppPrefsKeys.reviewFirstOpenAt);
    if (firstOpen == null ||
        t.millisecondsSinceEpoch - firstOpen < minInstallAge.inMilliseconds) {
      return false;
    }
    if ((prefs.getInt(AppPrefsKeys.reviewActiveDays) ?? 0) < minActiveDays) {
      return false;
    }
    final count = prefs.getInt(AppPrefsKeys.reviewRequestCount) ?? 0;
    if (count >= maxRequests) return false;
    final lastAt = prefs.getInt(AppPrefsKeys.reviewLastRequestAt);
    if (lastAt != null &&
        t.millisecondsSinceEpoch - lastAt < minInterval.inMilliseconds) {
      return false;
    }

    try {
      if (!await api.isAvailable()) return false;
      await api.requestReview();
    } catch (_) {
      return false;
    }
    await prefs.setInt(AppPrefsKeys.reviewRequestCount, count + 1);
    await prefs.setInt(
      AppPrefsKeys.reviewLastRequestAt,
      t.millisecondsSinceEpoch,
    );
    return true;
  }

  /// 설정 > 도움·문의 '스토어에서 평가하기'. 조건 없이 Play 스토어 앱 페이지를 연다.
  static Future<void> openStoreListing() => api.openStoreListing();
}

/// 테스트에서 바꿔 끼우는 얇은 래퍼.
abstract class ReviewApi {
  Future<bool> isAvailable();
  Future<void> requestReview();
  Future<void> openStoreListing();
}

class _InAppReviewApi implements ReviewApi {
  final _review = InAppReview.instance;

  @override
  Future<bool> isAvailable() => _review.isAvailable();

  @override
  Future<void> requestReview() => _review.requestReview();

  @override
  Future<void> openStoreListing() => _review.openStoreListing();
}
