import 'package:package_info_plus/package_info_plus.dart';

class ServerContract {
  static const protocolVersion = 3;
  static String productVersion = '';

  static Future<void> loadProductVersion() async {
    if (productVersion.isNotEmpty) return;
    final info = await PackageInfo.fromPlatform();
    productVersion = '${info.version}+${info.buildNumber}';
  }

  static const apiPrefix = '/api/v1';
  static const apiKeyHeader = 'X-API-Key';
  static const wsEventsPath = '/ws/events';
  static const wsApiKeyQuery = 'api_key';

  static const summaryPath = '$apiPrefix/summary';
  static const filesPath = '$apiPrefix/files';
  static const statsPath = '$apiPrefix/stats';
  static const statsOverviewPath = '$apiPrefix/stats/overview';
  static const statsMapPath = '$apiPrefix/stats/map';
  static const statsMapPointsPath = '$apiPrefix/stats/map/points';
  static const statsMapMissingPath = '$apiPrefix/stats/map/missing';
  static const statsMapProgressPath = '$apiPrefix/stats/map/progress';
  static const maintenanceStatusPath = '$apiPrefix/maintenance/status';
  static const watchlistPath = '$apiPrefix/watchlist';
  static const duplicateGroupsPath = '$apiPrefix/duplicates/groups';
  static const editorSchemaPath = '$apiPrefix/editor/schema';
  static const crawlEnqueuePath = '$apiPrefix/crawl/enqueue';
  static const crawlStatusPath = '$apiPrefix/crawl/status';
  static const crawlDonePath = '$apiPrefix/crawl/done';
  static const crawlResultsPath = '$apiPrefix/crawl/results';
  static const crawlConfigPath = '$apiPrefix/crawl/config';
  static const crawlStartPath = '$apiPrefix/crawl/start';
  static const crawlKillPath = '$apiPrefix/crawl/kill';
  static const appConfigPath = '$apiPrefix/app/config';
  static const settingsDbPath = '$apiPrefix/settings/db';
  static const settingsDbUploadPath = '$apiPrefix/settings/db/upload';
  static const settingsPath = '$apiPrefix/settings';
  static const ratingStartPath = '$apiPrefix/rating/start';
  static const filesDownloadPath = '$apiPrefix/files/download';
  static const filesMultiDownloadPath = '$apiPrefix/files/download-multi';
  static const filesDeleteMultiPath = '$apiPrefix/files/delete-multi';
  static const serverVersionPath = '$apiPrefix/server/version';
  static const sunwiPayloadPath = '$apiPrefix/sunwi/payload';

  // 서버의 커뮤니티 계정(서버가 인증·세션 주인, 폰은 토큰을 받지 않음). capability `community_account`.
  static const communityAuthStatusPath = '$apiPrefix/community-auth/status';
  static const communityAuthStartPath = '$apiPrefix/community-auth/start';
  static const communityAuthConfirmPath = '$apiPrefix/community-auth/confirm';
  static const communityAuthCancelPath = '$apiPrefix/community-auth/cancel';
  // 2026-09-27: 서버 `/api/v1/community-auth/disconnect` 는 없앴다(카카오 로그인 필수, 사용자 결정: 경로 삭제). 필요해지면 되살린다.
  // static const communityAuthDisconnectPath =
  //     '$apiPrefix/community-auth/disconnect';
  static const communityAccountCapability = 'community_account';

  // 커뮤니티 게이트·초기화 (서버 job 제어, Client 모드).
  // 민감 제어(초기화 시작·수동 업로드)는 `X-Community-User-Token`(폰 access token)으로
  // 서버가 GoTrue `/user` 로 검증해 서버 연결 사용자와 같을 때만 허용한다.
  static const communityUserTokenHeader = 'X-Community-User-Token';
  static const communityGatePath = '$apiPrefix/community/gate';
  static const communityRebuildPath = '$apiPrefix/community/rebuild';
  static const communityRebuildStartPath = '$apiPrefix/community/rebuild/start';
  static const communityRebuildResumePath =
      '$apiPrefix/community/rebuild/resume';

  static String normalizeBaseUrl(String baseUrl) =>
      baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');

  static String reportsPath(String category) => '$apiPrefix/reports/$category';
  static String duplicateGroupPath(String groupId) =>
      '$duplicateGroupsPath/$groupId';
  static String editorRecordPath(String category, String recordId) =>
      '$apiPrefix/editor/$category/$recordId';

  static String sunwiExportPath(String kind) => '$apiPrefix/sunwi/export/$kind';

  static Uri apiUri(
    String baseUrl,
    String path, {
    Map<String, String>? queryParameters,
  }) {
    final normalized = normalizeBaseUrl(baseUrl);
    return Uri.parse('$normalized$path').replace(
      queryParameters: queryParameters == null || queryParameters.isEmpty
          ? null
          : queryParameters,
    );
  }

  static Map<String, String> apiHeaders(
    String apiKey, {
    bool includeJsonContentType = true,
  }) {
    final headers = <String, String>{
      apiKeyHeader: apiKey,
      'X-SafetyReport-Client': 'mobile',
      'X-SafetyReport-Version': productVersion,
      'X-SafetyReport-Protocol': '$protocolVersion',
    };
    if (includeJsonContentType) {
      headers['Content-Type'] = 'application/json';
    }
    return headers;
  }

  static Uri wsBaseUri(String baseUrl) {
    final uri = Uri.parse(normalizeBaseUrl(baseUrl));
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  static Uri wsEventsUri(String baseUrl, String apiKey) =>
      wsClientUri(baseUrl, apiKey, wsEventsPath);

  static Uri wsClientUri(String baseUrl, String apiKey, String path) {
    return wsBaseUri(baseUrl).replace(
      path: path,
      queryParameters: {
        wsApiKeyQuery: apiKey,
        'client_type': 'mobile',
        'client_version': productVersion,
        'client_protocol': '$protocolVersion',
      },
    );
  }
}
