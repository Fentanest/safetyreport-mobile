import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs_keys.dart';
import 'local_db_service.dart';

/// SettingsScreen 이 모드 전환 시 SetupScreen 에 넘기는 임시 액션.
///
/// 이전에는 `'convert:<path>'` / `'copy:<path>'` / `'file:<path>'` 같은
/// 문자열 포맷을 두 화면이 각자 파싱했다. 이 클래스가 단일 source of truth.
///
/// 적용은 [apply] 가 `LocalDbService.importFromServerDb` /
/// `LocalDbService.replaceFromBackup` 둘 중 하나로 분기한다.
sealed class PendingDbImportAction {
  const PendingDbImportAction();

  /// 적용 결과 사람용 메시지 (성공 시 SnackBar 본문). null 이면 호출부가 메시지 안 띄움.
  Future<String?> apply();

  /// 테스트에서 실제 DB 교체 대신 쓰는 적용 함수. null 이면 [apply].
  @visibleForTesting
  static Future<String?> Function(PendingDbImportAction action)? applyOverride;

  static Future<String?> _runApply(PendingDbImportAction action) =>
      (applyOverride ?? (a) => a.apply())(action);

  String encode();

  /// 가져올 .db 파일 경로(받은 서버 DB·고른 백업). 실패 안내에 보여 준다.
  String get path;

  static PendingDbImportAction? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('convert:')) {
      return ConvertServerDbAction(raw.substring('convert:'.length));
    }
    if (raw.startsWith('copy:')) {
      return CopyMobileBackupAction(raw.substring('copy:'.length));
    }
    if (raw.startsWith('file:')) {
      return DetectAndApplyDbFileAction(raw.substring('file:'.length));
    }
    return null;
  }

  /// 저장된 대기 작업을 읽는다. 지우지 않는다 — 적용에 성공하거나 사용자가 버릴 때만 지운다(SQ-B03).
  static Future<PendingDbImportAction?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(AppPrefsKeys.pendingDbImport));
  }

  /// 저장된 값이 [action] 일 때만 지운다(그사이 새 작업이 저장됐으면 그것은 남긴다).
  static Future<void> _clearIfCurrent(PendingDbImportAction action) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppPrefsKeys.pendingDbImport) == action.encode()) {
      await prefs.remove(AppPrefsKeys.pendingDbImport);
    }
  }

  /// 대기 작업이 있으면 적용한다.
  ///
  /// - 성공하면 그때 지운다.
  /// - 실패하면 남긴 채 [onFailure] 로 묻는다: [PendingDbImportFailureChoice.retry] 면 다시 적용,
  ///   [PendingDbImportFailureChoice.discard] 면 지우고 끝, null(물을 수 없음)이면 남긴 채 끝.
  ///
  /// 호출부는 결과가 [PendingDbImportStatus.kept] 이면 새 모드를 켜지 않는다(다음 로그인에서 다시 시도).
  static Future<PendingDbImportOutcome> applyPending({
    required Future<PendingDbImportFailureChoice?> Function(
      PendingDbImportAction action,
      Object error,
    )
    onFailure,
  }) async {
    final action = await read();
    if (action == null) return const PendingDbImportOutcome._none();
    while (true) {
      try {
        final message = await _runApply(action);
        await _clearIfCurrent(action);
        return PendingDbImportOutcome._(
          PendingDbImportStatus.applied,
          action,
          message: message,
        );
      } catch (e) {
        final choice = await onFailure(action, e);
        switch (choice) {
          case PendingDbImportFailureChoice.retry:
            continue;
          case PendingDbImportFailureChoice.discard:
            await _clearIfCurrent(action);
            return PendingDbImportOutcome._(
              PendingDbImportStatus.discarded,
              action,
              error: e,
            );
          case null:
            return PendingDbImportOutcome._(
              PendingDbImportStatus.kept,
              action,
              error: e,
            );
        }
      }
    }
  }

  static Future<void> save(PendingDbImportAction? action) async {
    final prefs = await SharedPreferences.getInstance();
    if (action == null) {
      await prefs.remove(AppPrefsKeys.pendingDbImport);
    } else {
      await prefs.setString(AppPrefsKeys.pendingDbImport, action.encode());
    }
  }
}

/// 가져오기 실패 시 사용자의 선택.
enum PendingDbImportFailureChoice { retry, discard }

/// [PendingDbImportAction.applyPending] 결과.
enum PendingDbImportStatus {
  /// 대기 작업이 없었다.
  none,

  /// 적용했고 대기 작업을 지웠다.
  applied,

  /// 실패했고 사용자가 버렸다(대기 작업을 지웠다. 받은 파일은 남아 있다).
  discarded,

  /// 실패했고 결정을 받지 못했다(대기 작업을 남겼다).
  kept,
}

class PendingDbImportOutcome {
  const PendingDbImportOutcome._(
    this.status,
    this.action, {
    this.message,
    this.error,
  });
  const PendingDbImportOutcome._none()
    : status = PendingDbImportStatus.none,
      action = null,
      message = null,
      error = null;

  final PendingDbImportStatus status;
  final PendingDbImportAction? action;

  /// 성공 메시지([PendingDbImportAction.apply] 반환값).
  final String? message;

  /// 마지막 실패.
  final Object? error;
}

/// 서버 형식 DB 파일을 받아 모바일 reports 테이블로 변환.
class ConvertServerDbAction extends PendingDbImportAction {
  @override
  final String path;
  const ConvertServerDbAction(this.path);

  @override
  String encode() => 'convert:$path';

  @override
  Future<String?> apply() async {
    final imported = await LocalDbService.importFromServerDb(path);
    return '서버 DB 변환 완료: $imported건 임포트';
  }
}

/// 모바일 형식 백업 .db 를 그대로 덮어쓰기.
class CopyMobileBackupAction extends PendingDbImportAction {
  @override
  final String path;
  const CopyMobileBackupAction(this.path);

  @override
  String encode() => 'copy:$path';

  @override
  Future<String?> apply() async {
    await LocalDbService.replaceFromBackup(path);
    return '백업 복원 완료: ${path.split('/').last}';
  }
}

/// 사용자가 직접 고른 .db 파일. 서버/모바일 형식을 자동 판별.
class DetectAndApplyDbFileAction extends PendingDbImportAction {
  @override
  final String path;
  const DetectAndApplyDbFileAction(this.path);

  @override
  String encode() => 'file:$path';

  @override
  Future<String?> apply() async {
    final kind = await LocalDbService.detectDbKind(path);
    if (kind == 'server') {
      final imported = await LocalDbService.importFromServerDb(path);
      return '서버 DB 변환 완료: $imported건 임포트';
    }
    if (kind == 'mobile') {
      await LocalDbService.replaceFromBackup(path);
      return '모바일 백업 복원 완료: ${path.split('/').last}';
    }
    throw Exception('알 수 없는 DB 형식입니다. 서버 DB 또는 모바일 백업 .db 파일만 사용할 수 있습니다.');
  }
}
