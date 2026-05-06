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

  String encode();

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

  static Future<PendingDbImportAction?> readAndClear() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(AppPrefsKeys.pendingDbImport);
    await prefs.remove(AppPrefsKeys.pendingDbImport);
    return decode(raw);
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

/// 서버 형식 DB 파일을 받아 모바일 reports 테이블로 변환.
class ConvertServerDbAction extends PendingDbImportAction {
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
    throw Exception(
      '알 수 없는 DB 형식입니다. 서버 DB 또는 모바일 백업 .db 파일만 사용할 수 있습니다.',
    );
  }
}
