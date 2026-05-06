import 'dart:io';

/// `mysafetyreport` 산출물 디렉토리 단일 소스.
///
/// Documents/mysafetyreport 가 우선이고, 일부 기기가 Documents 쓰기를 막는 경우
/// Download/mysafetyreport 로 fallback 한다. 이 분기 로직은 settings/file_browser/
/// sunwi 모두 동일했으므로 한 곳에서만 다루도록 모았다.
class AppStoragePaths {
  AppStoragePaths._();

  static const _documentsRoot = '/storage/emulated/0/Documents/mysafetyreport';
  static const _downloadRoot = '/storage/emulated/0/Download/mysafetyreport';

  /// 백업/내보내기 루트 디렉토리. 존재하지 않으면 생성하고, Documents 가 막혀 있으면
  /// Download 로 fallback. 어떤 경로도 만들 수 없으면 마지막 시도 경로의
  /// Directory 를 그대로 반환한다 (호출부에서 IO 예외 처리).
  static Directory exportsRoot() => _ensure('');

  /// sunwi/ 처럼 기능별 하위 디렉토리. [subdir] 는 슬래시 없는 단일 이름이어야 한다.
  static Directory subDir(String subdir) {
    final clean = subdir.replaceAll(RegExp(r'^/+|/+$'), '');
    return _ensure(clean);
  }

  static Directory _ensure(String suffix) {
    final docs = Directory(
      suffix.isEmpty ? _documentsRoot : '$_documentsRoot/$suffix',
    );
    if (docs.existsSync()) return docs;
    try {
      docs.createSync(recursive: true);
      return docs;
    } catch (_) {
      final fallback = Directory(
        suffix.isEmpty ? _downloadRoot : '$_downloadRoot/$suffix',
      );
      if (!fallback.existsSync()) {
        try {
          fallback.createSync(recursive: true);
        } catch (_) {/* let caller surface IO error */}
      }
      return fallback;
    }
  }

  /// UI 안내 문구용 표시 경로 ("Documents/mysafetyreport").
  static const exportsDisplayLabel = 'Documents/mysafetyreport';
}
