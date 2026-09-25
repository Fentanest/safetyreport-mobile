// community-ingest REST 클라이언트.
//
// POST {url}/functions/v1/community-ingest — apikey + Bearer.
// 타임아웃: 연결 5s·전체 30s. envelope source_app=safetyreport-mobile,
// source_mode=standalone, parser_version=mobile-parser-1.
// Client 모드에서는 어떤 업로드·등록도 하지 않는다(호출자가 차단).
import 'dart:convert';

import 'package:http/http.dart' as http;

/// manifest 페이지 조회 (GET {url}/functions/v1/community-ingest/manifest).
class CommunityIngestClient {
  CommunityIngestClient({
    required this.supabaseUrl,
    required this.publishableKey,
    http.Client? httpClient,
    this.clientVersion = '',
  }) : _http = httpClient ?? http.Client();

  final String supabaseUrl;
  final String publishableKey;
  final String clientVersion;
  final http.Client _http;

  Map<String, String> _headers(String accessToken) => {
        'Content-Type': 'application/json',
        'apikey': publishableKey,
        'Authorization': 'Bearer $accessToken',
      };

  Uri _ingestUri() =>
      Uri.parse('$supabaseUrl/functions/v1/community-ingest');

  /// envelope 전송. 네트워크·타임아웃은 예외로, HTTP 오류는 본문 그대로 반환한다.
  Future<Map<String, Object?>> postIngest(
    String accessToken,
    Map<String, Object?> envelope,
  ) async {
    final body = jsonEncode(envelope);
    if (utf8.encode(body).length > 256 * 1024) {
      throw const CommunityIngestTooLarge();
    }
    http.Response res;
    try {
      res = await _http
          .post(_ingestUri(), headers: _headers(accessToken), body: body)
          .timeout(const Duration(seconds: 30));
    } on CommunityIngestTooLarge {
      rethrow;
    } catch (e) {
      throw CommunityIngestTransport('transport: $e');
    }
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map) {
        return {
          'httpStatus': res.statusCode,
          ...Map<String, Object?>.from(decoded),
        };
      }
    } catch (_) {}
    return {
      'httpStatus': res.statusCode,
      'error': {
        'code': 'bad_response',
        'message': 'ingest 응답을 읽을 수 없습니다.',
        'request_id': '',
        'retryable': res.statusCode >= 500,
      },
    };
  }

  /// manifest 페이지 조회. 실패하면 null.
  Future<Map<String, Object?>?> fetchManifestPage(
    String accessToken,
    String connectionId, {
    String? after,
    int limit = 5000,
  }) async {
    final query = <String, String>{
      'connection_id': connectionId,
      'limit': '$limit',
    };
    if (after != null) query['after'] = after;
    final uri = Uri.parse('$supabaseUrl/functions/v1/community-ingest/manifest')
        .replace(queryParameters: query);
    try {
      final res = await _http
          .get(uri, headers: _headers(accessToken))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      return Map<String, Object?>.from(decoded);
    } catch (_) {
      return null;
    }
  }
}

class CommunityIngestTooLarge implements Exception {
  const CommunityIngestTooLarge();
}

class CommunityIngestTransport implements Exception {
  CommunityIngestTransport(this.message);
  final String message;
  @override
  String toString() => message;
}
