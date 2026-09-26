import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../community/community_store.dart';
import '../community/upload/community_schedule.dart';
import '../community/upload/community_uploader.dart' show UploadRunResult;
import '../community/upload/upload_background.dart';
import '../models/app_mode.dart';
import 'app_prefs_keys.dart';
import 'standalone_auth_service.dart';

/// WorkManager 백그라운드 isolate 진입점(main.dart 가 initialize 에 넘긴다).
@pragma('vm:entry-point')
void backgroundTaskDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    if (task == communityPeriodicTaskName || task == communityMidnightTaskName) {
      // 상태를 저장했으면 true, 저장 전 예기치 못한 예외면 false(OS 가 백오프로 다시 실행).
      return runCommunityUploadTask(task);
    }
    try {
      if (task == BackgroundLoginCheck.taskName) {
        await BackgroundLoginCheck.run();
      }
    } catch (_) {
      // 로그인 점검은 부가 기능이다. 실패해도 WorkManager 재시도를 요청하지 않는다.
    }
    return true;
  });
}

/// 커뮤니티 업로드 백그라운드 작업 (UC-1 §2 모바일).
///
/// Standalone(데모 제외) + context active 일 때만. 게이트 캐시(600초)가 오래됐으면 [refreshGateHeadless] 로 중앙 상태를
/// 한 번 다시 확인하고, ok 일 때만 보낸다(일시 장애면 상태를 보존하고 끝, 명시적 거절이면 차단 기록).
/// - 자정 작업: 그날 key 를 `catchUp('os')` 로 실행하고 다음 자정 작업을 다시 예약한다.
/// - 주기 작업(1시간): 누락 자정 보충(`catchUp`) 뒤, 재시도 시각이 된 행이 있으면 `recovery` — 자정 성공 여부와 별개.
/// 반환: 상태를 저장했거나 할 일이 없으면 true, 저장 전 예기치 못한 예외면 false.
/// 정확 알람·상시 FGS·배터리 예외는 요구하지 않는다.
@pragma('vm:entry-point')
Future<bool> runCommunityUploadTask(
  String task, {
  DateTime? now,
  @visibleForTesting Future<CommunityStore?> Function()? openStore,
  @visibleForTesting Future<UploadRunResult> Function(String trigger)? upload,
  @visibleForTesting Future<bool> Function(CommunityStore store, {DateTime? now})? recoveryCheck,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final mode = AppModeX.fromString(prefs.getString(AppPrefsKeys.appMode));
    if (mode != AppMode.standalone) return true;
    if (prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false) return true;
    final store = await (openStore ?? openCommunityStoreForBackground)();
    if (store == null) return false; // community.db 를 열지 못함 — 저장 전 실패
    if (task == communityMidnightTaskName) await registerMidnightTask(now: now);
    if (await store.activeContext() == null) return true;
    if (!await isGateCacheFresh(prefs, now ?? DateTime.now())) {
      final gate = await refreshGateHeadless(store, prefs: prefs);
      if (gate != HeadlessGate.ok) return true;
    }
    final Future<UploadRunResult> Function(String) run =
        upload ?? ((String trigger) => uploadFromBackground(store, trigger));
    await catchUp('os', store: store, runUpload: run, now: now);
    // 복구는 자정 결과와 별개다(자정 key 가 다른 실행에 잡혀 deferred 여도 재시도 시각이 된 행은 보낸다)
    if (task == communityPeriodicTaskName && await (recoveryCheck ?? recoveryDue)(store, now: now)) {
      await run('recovery');
    }
    return true;
  } catch (_) {
    return false;
  }
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
