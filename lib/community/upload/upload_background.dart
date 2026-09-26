// 백그라운드 isolate 용 업로드 조립 (background_login_check.dart 에서 호출).
//
// 포그라운드 T5 gate 에 의존하지 않는다. 진입 전에 게이트 캐시(600초 이내 성공)를
// 확인했으므로, 여기서는 캐시 기반 gate 로 uploader 의 requireFresh 를 만족한다.
import 'package:package_info_plus/package_info_plus.dart';

import '../../models/app_mode.dart';
import '../../services/community_auth_config.dart';
import '../../services/community_auth_service.dart';
import '../community_store.dart';
import 'community_schedule.dart';
import 'community_uploader.dart';

Future<CommunityStore?> openCommunityStoreForBackground() async {
  try {
    return await CommunityStore.open();
  } catch (_) {
    return null;
  }
}

class _BackgroundTokens implements CommunityTokenSource {
  @override
  Future<String?> getAccessToken() =>
      CommunityAuthService.instance.getAccessToken();
}

Future<UploadRunResult> uploadFromBackground(
    CommunityStore store, String trigger) async {
  final config = CommunityAuthConfig.fromEnvironment;
  var version = '';
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  final uploader = CommunityUploader(
    gate: CacheGateCheck(),
    tokens: _BackgroundTokens(),
    appMode: () async => AppMode.standalone,
    supabaseUrl: config.supabaseUrl,
    publishableKey: config.publishableKey,
    clientVersion: version,
    openStore: () async => store,
  );
  return uploader.requestCommunityUpload(trigger);
}
