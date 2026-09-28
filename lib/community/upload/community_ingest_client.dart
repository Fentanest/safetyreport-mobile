// community-ingest REST 클라이언트.
//
// POST {url}/functions/v1/community-ingest — apikey + Bearer.
// 타임아웃: 전체 30s(초과하면 요청을 끊는다). envelope source_app=safetyreport-mobile,
// source_mode=standalone, parser_version=mobile-parser-4.
// Client 모드에서는 어떤 업로드·등록도 하지 않는다(호출자가 차단).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// manifest 페이지 조회 (GET {url}/functions/v1/community-ingest/manifest).
class CommunityIngestClient {
  CommunityIngestClient({
    required this.supabaseUrl,
    required this.publishableKey,
    http.Client? httpClient,
    this.clientVersion = '',
  })  : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final String supabaseUrl;
  final String publishableKey;
  final String clientVersion;
  final http.Client _http;
  final bool _ownsClient;

  static const int maxResponseBytes = 1024 * 1024;

  Map<String, String> _headers(String accessToken) => {
        'Content-Type': 'application/json',
        'apikey': publishableKey,
        'Authorization': 'Bearer $accessToken',
      };

  Uri _ingestUri() =>
      Uri.parse('$supabaseUrl/functions/v1/community-ingest');

  /// envelope 전송 1회(재시도 없음 — 재시도는 outbox·전송 제어가 맡는다, UC-1).
  /// 전송 계층 결과(실제 HTTP 상태·헤더·본문 바이트)를 그대로 돌려준다. 판정은 `upload_policy.interpretResponse`.
  /// 연결·DNS·timeout 은 status=null. 리다이렉트는 따르지 않고 502 로 본다(PC 와 같음). 응답 본문은 최대 1MiB 까지만 읽는다.
  Future<IngestTransport> postEnvelopeBytes(String accessToken, List<int> body,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final abort = Completer<void>();
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request = http.AbortableRequest('POST', _ingestUri(), abortTrigger: abort.future)
        ..followRedirects = false
        ..headers.addAll(_headers(accessToken))
        ..bodyBytes = body;
      final response = await _http.send(request).timeout(timeout + const Duration(seconds: 1));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        final room = maxResponseBytes - bytes.length;
        if (room <= 0) break;
        bytes.addAll(chunk.length > room ? chunk.sublist(0, room) : chunk);
        if (bytes.length >= maxResponseBytes) break;
      }
      final status = response.statusCode;
      return IngestTransport(
        status: (status >= 300 && status < 400) ? 502 : status,
        rawStatus: status,
        headers: response.headers,
        body: bytes,
      );
    } catch (_) {
      return const IngestTransport(status: null, rawStatus: null, headers: {}, body: null);
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete(); // 읽기를 끝냈거나 실패했으면 남은 연결을 끊는다
    }
  }

  /// 실행 끝에 닫는다(실행 단위로 client 하나 — 주입받은 client 는 호출자가 닫는다).
  void close() {
    if (_ownsClient) _http.close();
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

/// 전송 계층 결과. status=null 은 연결·timeout 실패(요청이 서버에 닿았는지 모름). [status] 는 판정용(3xx → 502),
/// [rawStatus] 는 실제 값.
class IngestTransport {
  const IngestTransport({required this.status, required this.rawStatus, required this.headers, required this.body});
  final int? status;
  final int? rawStatus;
  final Map<String, String> headers;
  final List<int>? body;
}
