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
      final decoded = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
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

  /// manifest 페이지 조회 — `POST {url}/functions/v1/community-ingest/manifest`
  /// 본문 `{"protocol":1,"connection_id","after","limit"}`(account-api.md). 형식이 하나라도 틀리면 null.
  Future<Map<String, Object?>?> fetchManifestPage(
    String accessToken,
    String connectionId, {
    String? after,
    int limit = 5000,
  }) async {
    final uri = Uri.parse('$supabaseUrl/functions/v1/community-ingest/manifest');
    final body = jsonEncode({
      'protocol': 1,
      'connection_id': connectionId,
      'after': after,
      'limit': limit.clamp(1, 5000),
    });
    try {
      final res = await _http
          .post(uri, headers: _headers(accessToken), body: body)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map) return null;
      final page = Map<String, Object?>.from(decoded);
      return validManifestPage(page) ? page : null;
    } catch (_) {
      return null;
    }
  }
}

final _hex24 = RegExp(r'^[0-9a-f]{24}$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _decimal = RegExp(r'^[0-9]+$');

/// manifest 응답 한 페이지 형식 검사(PC `_valid_manifest_page` 와 같은 규칙).
bool validManifestPage(Map<String, Object?> p) {
  if (p['protocol'] != 1) return false;
  final total = p['total'];
  final token = p['manifest_token'];
  final keys = p['key_prefixes'];
  final next = p['next_after'];
  if (total is! int || total < 0) return false;
  if (token is! String || !_decimal.hasMatch(token)) return false;
  if (keys is! List || !keys.every((k) => k is String && _hex24.hasMatch(k))) return false;
  if (p['dataset_key'] is! String || p['writer_epoch'] is! int) return false;
  return next == null || (next is String && _hex64.hasMatch(next));
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
