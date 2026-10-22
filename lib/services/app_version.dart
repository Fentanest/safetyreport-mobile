import 'package:package_info_plus/package_info_plus.dart';

/// 이 앱의 버전(`PackageInfo.version`, 빌드 번호 제외) — 진입점(앱 `main`, WorkManager 디스패처)에서 한 번 읽어 둔다.
///
/// 필수 버전 판정(CLIENT-RULES 6절)과 community-account 버전 헤더(6-3)가 쓴다. 라이브러리 안에서 플랫폼 정보를
/// 그때그때 읽지 않는다(위젯 시험의 가짜 시간에서 파일 읽기가 끝나지 않는다). 읽지 못했으면 null —
/// 그때는 헤더를 붙이지 않고 잠금 판정도 하지 않는다(먹통 방지).
class AppVersion {
  AppVersion._();

  static String? value;

  static Future<String?> load() async {
    if (value != null) return value;
    try {
      value = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    return value;
  }
}
