import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../models/app_mode.dart';
import 'app_prefs_keys.dart';
import 'standalone_auth_service.dart';

/// WorkManager 백그라운드 isolate 진입점(main.dart 가 initialize 에 넘긴다).
@pragma('vm:entry-point')
void backgroundTaskDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    try {
      if (task == BackgroundLoginCheck.taskName) {
        await BackgroundLoginCheck.run();
      }
    } catch (_) {
      // 점검은 부가 기능이다. 실패해도 WorkManager 재시도를 요청하지 않고 다음 날 다시 한다.
    }
    return true;
  });
}

/// Standalone 하루 1회 로그인 점검.
///
/// 토큰은 1시간짜리라 미리 갱신해 둘 이유는 없다. 대신 앱이 닫혀 있는 동안 비밀번호가 바뀌거나
/// 계정이 잠긴 것을 미리 알아채서, 사용자가 동기화하다 실패하기 전에 "재로그인 필요" 알림을 띄운다.
/// 알림은 Kotlin `SafetyReportApplication` 이 [AppPrefsKeys.standaloneAuthAlert] 변경을 듣고 띄운다
/// (백그라운드 엔진에는 MainActivity 의 MethodChannel 이 없다).
class BackgroundLoginCheck {
  static const taskName = 'standaloneDailyLoginCheck';
  static const _uniqueName = 'standalone-daily-login-check';

  /// 같은 사유로 매일 알리지 않는다.
  static const alertCooldown = Duration(hours: 72);

  /// 백그라운드에서 한 번 실행. 알림을 요청했으면 true.
  static Future<bool> run({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // 앱 isolate 가 쓴 최신 값을 읽는다
    final mode = AppModeX.fromString(prefs.getString(AppPrefsKeys.appMode));
    if (mode != AppMode.standalone) return false;
    if (prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false) return false;
    // 최근에 앱이 로그인해 둔 토큰이 살아 있으면 점검할 필요가 없다.
    if (await StandaloneAuthService.isTokenValid()) return false;

    final result = await StandaloneAuthService.relogin();
    if (!result.needsManualLogin) return false; // 성공 또는 일시 오류(다음 날 다시)
    return _requestAlert(prefs, result.message, now ?? DateTime.now());
  }

  static Future<bool> _requestAlert(
    SharedPreferences prefs,
    String message,
    DateTime now,
  ) async {
    final previous = prefs.getString(AppPrefsKeys.standaloneAuthAlert) ?? '';
    final previousAt = int.tryParse(previous.split('|').first);
    if (previousAt != null &&
        now.millisecondsSinceEpoch - previousAt <
            alertCooldown.inMilliseconds) {
      return false;
    }
    await prefs.setString(
      AppPrefsKeys.standaloneAuthAlert,
      '${now.millisecondsSinceEpoch}|$message',
    );
    return true;
  }

  @visibleForTesting
  static bool schedulingEnabled = true;

  /// Standalone(데모 제외) 로그인 상태에서 켠다. 이미 등록돼 있으면 그대로 둔다.
  static Future<void> schedule() async {
    if (!schedulingEnabled) return;
    try {
      await Workmanager().registerPeriodicTask(
        _uniqueName,
        taskName,
        frequency: const Duration(hours: 24),
        initialDelay: const Duration(hours: 6),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {
      // 플러그인이 없는 환경(테스트 등)에서는 조용히 넘어간다.
    }
  }

  /// Client 모드 전환·데모·로그아웃 때 끈다.
  static Future<void> cancel() async {
    if (!schedulingEnabled) return;
    try {
      await Workmanager().cancelByUniqueName(_uniqueName);
    } catch (_) {}
  }
}
