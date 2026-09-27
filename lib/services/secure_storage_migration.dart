// flutter_secure_storage 9 → 10 이관 확정 (Play H2.h.b 수정 1단계, docs/architecture/data-contracts.md 자격증명 절).
//
// v10 은 보안 저장소를 **처음 열 때** v9 자료를 새 cipher 로 옮긴다. 앱이 한동안 보안 저장소를 열지 않으면 이관 없이 다음 릴리즈(v11 —
// v10 이전 방식 자료를 읽지 못함)로 넘어갈 수 있으므로, 포그라운드 앱 시작 때 앱이 쓰는 두 옵션으로 곧바로 열어 이관을 끝내고 표시를 남긴다.
// 백그라운드 엔진(WorkManager)은 표시가 생기기 전에는 보안 저장소를 열지 않는다 — 두 엔진이 동시에 첫 이관을 하지 않게.
//
// 이관이 확인되지 않으면 앱은 평소 화면으로 들어가지 않는다(main.dart → SecureStorageRecoveryScreen). 플러그인은 ESP 이관이 실패하면 ESP 로
// 되돌아가 성공을 알리는데, 그 상태에서 새로 쓴 값은 다음 이관 때 망가진다 — 로그인·토큰 갱신·연결 등록·설정 초기화가 돌지 않게 한다.
// 사용자는 앱을 다시 시작해 재시도한다. 로그인 정보를 지워 우회하는 경로는 두지 않는다(카카오 로그인은 필수 — 2026-09-27 사용자 결정).
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs_keys.dart';

class SecureStorageMigration {
  SecureStorageMigration._();

  // 앱이 실제로 쓰는 두 옵션(standalone_auth_service·community_auth_service 의 ESP, community_gate·upload_background 의 기본).
  // ignore: deprecated_member_use
  static const _esp = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const _default = FlutterSecureStorage();
  static const _channel = MethodChannel('com.fentanest.mysafetyreport/secure_storage');

  static Future<bool> isDone([SharedPreferences? prefs]) async {
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      if (prefs == null) await p.reload();
      return p.getBool(AppPrefsKeys.secureStorageV10Migrated) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 포그라운드 앱 시작 때 한 번. 두 옵션으로 보안 저장소를 열어(읽기만) 이관을 끝내고 표시를 남긴다.
  ///
  /// 읽기가 예외 없이 끝났다고 이관된 것은 아니다 — 플러그인은 ESP 이관이 실패하면 ESP 로 되돌아가 성공을 알리고, 그때 앱의 키는 null 로 읽힌다.
  /// 그래서 Android 는 자료 파일에 옮겨지지 않은 v9 ESP 항목이 **0개**일 때만 표시한다(네이티브가 키 이름만 센다, 값은 읽지 않음).
  /// 실패하면 표시를 남기지 않고 false(자료를 지우거나 쓰지 않는다).
  static Future<bool> ensureMigrated({
    @visibleForTesting FlutterSecureStorage? esp,
    @visibleForTesting FlutterSecureStorage? defaultStorage,
    @visibleForTesting Future<int> Function()? unmigratedEntries,
    @visibleForTesting bool? isAndroid,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (await isDone(prefs)) return true;
    try {
      await (esp ?? _esp).read(key: 'community_session_v1');
      await (defaultStorage ?? _default).read(key: 'community_connection_v1');
      if (isAndroid ?? (defaultTargetPlatform == TargetPlatform.android && !kIsWeb)) {
        final left = await (unmigratedEntries ?? _unmigratedEntries)();
        if (left != 0) return false; // 옮겨지지 않은 v9 자료가 있거나 확인 못 함
      }
      await prefs.setBool(AppPrefsKeys.secureStorageV10Migrated, true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<int> _unmigratedEntries() async =>
      (await _channel.invokeMethod<int>('unmigratedLegacyEntries')) ?? -1;
}
