// 앱 기본 uploader 조립 (T5 가 CommunityGate 를 넘긴다).
//
// Standalone 세션·공개 설정·앱 모드·버전을 읽어 CommunityUploader 를 만든다.
// Client·데모 판정은 uploader 내부에서 한다(어떤 업로드·등록도 하지 않음).
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/app_mode.dart';
import '../../services/app_prefs_keys.dart';
import '../../services/community_auth_config.dart';
import '../../services/community_auth_service.dart';
import '../community_store.dart';
import 'community_uploader.dart';

class _AuthTokenSource implements CommunityTokenSource {
  @override
  Future<CommunityTokenResult> getAccessTokenResult({String? rejected}) =>
      CommunityAuthService.instance.getAccessTokenResult(rejected: rejected);
}

/// 앱 기본 uploader. [gate] 는 T5 의 CommunityGate 를 어댑터로 넘긴다.
Future<CommunityUploader> buildDefaultUploader({
  required CommunityGateCheck gate,
  http.Client? httpClient,
  Future<CommunityStore> Function()? openStore,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final mode = AppModeX.fromString(prefs.getString(AppPrefsKeys.appMode));
  final demo = prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false;
  final config = CommunityAuthConfig.fromEnvironment;
  var version = '';
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  return CommunityUploader(
    gate: gate,
    tokens: _AuthTokenSource(),
    appMode: () async => mode,
    demoMode: () async => demo, // 데모는 writer 가 아니다(업로드 없음)
    supabaseUrl: config.supabaseUrl,
    publishableKey: config.publishableKey,
    clientVersion: version,
    httpClient: httpClient,
    openStore: openStore,
  );
}
