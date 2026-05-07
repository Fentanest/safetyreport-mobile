class ServerContract {
  static const apiPrefix = '/api/v1';
  static const apiKeyHeader = 'X-API-Key';
  static const wsEventsPath = '/ws/events';
  static const wsApiKeyQuery = 'api_key';

  static const summaryPath = '$apiPrefix/summary';
  static const filesPath = '$apiPrefix/files';
  static const statsPath = '$apiPrefix/stats';
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
  static const crawlResumePath = '$apiPrefix/crawl/resume';
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
    final headers = <String, String>{apiKeyHeader: apiKey};
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

  static Uri wsEventsUri(String baseUrl, String apiKey) {
    return wsBaseUri(
      baseUrl,
    ).replace(path: wsEventsPath, queryParameters: {wsApiKeyQuery: apiKey});
  }
}
