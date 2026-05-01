import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/report.dart';
import '../models/file_item.dart';
import '../models/agency_stats.dart';

class ApiService {
  final String baseUrl;
  final String apiKey;

  ApiService({required this.baseUrl, required this.apiKey});

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-API-Key': apiKey,
  };

  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() request, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        return await request().timeout(timeout);
      } on SocketException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      }
      if (attempt < 3) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    throw Exception('네트워크 오류 (3회 재시도 실패): $lastError');
  }

  Future<http.StreamedResponse> _sendMultipartWithRetry(
    Uri uri,
    String filePath,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final req = http.MultipartRequest('POST', uri);
        req.headers.addAll({'X-API-Key': apiKey});
        req.files.add(await http.MultipartFile.fromPath('file', filePath));
        return await req.send().timeout(const Duration(minutes: 5));
      } on SocketException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      }
      if (attempt < 3) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    throw Exception('업로드 네트워크 오류 (3회 재시도 실패): $lastError');
  }

  Future<DashboardStats> getSummary() async {
    final response = await _sendWithRetry(
      () => http.get(Uri.parse('$baseUrl/api/v1/summary'), headers: _headers),
    );
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return DashboardStats.fromJson(json['data']);
    } else {
      throw Exception('Failed to load summary');
    }
  }

  Future<List<Report>> getReports(String category) async {
    final response = await _sendWithRetry(
      () => http.get(
        Uri.parse('$baseUrl/api/v1/reports/$category'),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      var list = json['data'] as List? ?? [];
      return list.map((i) => Report.fromJson(i)).toList();
    } else {
      throw Exception('Failed to load reports');
    }
  }

  Future<List<FileItem>> getFiles(String path) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/files',
    ).replace(queryParameters: path.isNotEmpty ? {'path': path} : null);
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
    );
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      final list = json['data'] as List? ?? [];
      return list.map((i) => FileItem.fromJson(i)).toList();
    } else {
      throw Exception('파일 목록 로드 실패: ${response.statusCode}');
    }
  }

  Future<AgencyStats> getStats({String? year, String? law}) async {
    final params = <String, String>{};
    if (year != null && year != 'all') params['year'] = year;
    if (law != null) params['law'] = law;
    final uri = Uri.parse(
      '$baseUrl/api/v1/stats',
    ).replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
    );
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return AgencyStats.fromJson(json['data'] as Map<String, dynamic>);
    } else {
      throw Exception('통계 로드 실패: ${response.statusCode}');
    }
  }

  Future<List<Report>> getWatchlist() async {
    final response = await _sendWithRetry(
      () => http.get(Uri.parse('$baseUrl/api/v1/watchlist'), headers: _headers),
    );
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      final list = json['data'] as List? ?? [];
      return list.map((i) => Report.fromJson(i)).toList();
    } else {
      throw Exception('감시 목록 로드 실패: ${response.statusCode}');
    }
  }

  Future<void> updateWatchlist(
    List<String> reportNumbers, {
    bool add = false,
  }) async {
    final response = await _sendWithRetry(
      () => http.post(
        Uri.parse('$baseUrl/api/v1/watchlist'),
        headers: _headers,
        body: jsonEncode({
          'report_numbers': reportNumbers,
          'action': add ? 'add' : 'remove',
        }),
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('감시 목록 업데이트 실패: ${response.statusCode}');
    }
  }

  Future<void> enqueueCrawl(String reportNumber) async {
    final response = await _sendWithRetry(
      () => http.post(
        Uri.parse('$baseUrl/api/v1/crawl/enqueue'),
        headers: _headers,
        body: jsonEncode({'report_number': reportNumber}),
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to enqueue crawl');
    }
  }

  Future<Map<String, dynamic>> getCrawlStatus() async {
    final response = await _sendWithRetry(
      () => http.get(
        Uri.parse('$baseUrl/api/v1/crawl/status'),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('상태 확인 실패');
  }

  Future<Map<String, dynamic>> getCrawlDone() async {
    final response = await _sendWithRetry(
      () =>
          http.get(Uri.parse('$baseUrl/api/v1/crawl/done'), headers: _headers),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('완료 확인 실패');
  }

  Future<List<Map<String, dynamic>>> fetchCrawlResults() async {
    final response = await _sendWithRetry(
      () => http.get(
        Uri.parse('$baseUrl/api/v1/crawl/results'),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return (json['data'] as List? ?? []).cast<Map<String, dynamic>>();
    }
    throw Exception('결과 조회 실패');
  }

  Future<Map<String, dynamic>> getCrawlConfig() async {
    final response = await _sendWithRetry(
      () => http.get(
        Uri.parse('$baseUrl/api/v1/crawl/config'),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return json['data'] as Map<String, dynamic>;
    }
    throw Exception('설정 조회 실패');
  }

  Future<void> startCrawl({
    required String loginMode,
    required String crawlType,
    required String crawlMode,
    required int maxEmptyPages,
    required String queueList,
  }) async {
    final response = await _sendWithRetry(
      () => http.post(
        Uri.parse('$baseUrl/api/v1/crawl/start'),
        headers: _headers,
        body: jsonEncode({
          'login_mode': loginMode,
          'crawl_type': crawlType,
          'crawl_mode': crawlMode,
          'max_empty_pages': maxEmptyPages,
          'queue_list': queueList,
        }),
      ),
    );
    if (response.statusCode != 200) {
      final msg = jsonDecode(response.body)['detail'] ?? '크롤링 시작 실패';
      throw Exception(msg);
    }
  }

  Future<void> killCrawl() async {
    final response = await _sendWithRetry(
      () =>
          http.post(Uri.parse('$baseUrl/api/v1/crawl/kill'), headers: _headers),
    );
    if (response.statusCode != 200) {
      final msg = jsonDecode(response.body)['detail'] ?? '중지 실패';
      throw Exception(msg);
    }
  }

  Future<void> resumeCrawl() async {
    final response = await _sendWithRetry(
      () => http.post(
        Uri.parse('$baseUrl/api/v1/crawl/resume'),
        headers: _headers,
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('재개 실패');
    }
  }

  Future<Map<String, dynamic>> getAppConfig() async {
    final response = await _sendWithRetry(
      () =>
          http.get(Uri.parse('$baseUrl/api/v1/app/config'), headers: _headers),
    );
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return json['data'] as Map<String, dynamic>;
    }
    throw Exception('앱 설정 조회 실패');
  }

  Future<Uint8List> downloadDb() async {
    // 네트워크 일시 오류 (errno 104 connection reset, 110 timeout, ECONNRESET 등) →
    // 1초 sleep 후 최대 3회 재시도. DB 는 MB 단위라 일시 끊김 가능성 높음.
    final response = await _sendWithRetry(
      () =>
          http.get(Uri.parse('$baseUrl/api/v1/settings/db'), headers: _headers),
      timeout: const Duration(minutes: 2),
    );
    if (response.statusCode == 200) return response.bodyBytes;
    throw Exception('DB 다운로드 실패: ${response.statusCode}');
  }

  /// .db 파일을 서버에 업로드해 복원. 서버는 모바일/서버 형식 자동 감지.
  /// 반환: {status, kind, imported, backup}
  Future<Map<String, dynamic>> uploadDb(String filePath) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/db/upload');
    final streamed = await _sendMultipartWithRetry(uri, filePath);
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200) {
      String detail = res.body;
      try {
        final j = jsonDecode(res.body);
        detail = (j['detail'] ?? j['message'] ?? res.body).toString();
      } catch (_) {}
      throw Exception('업로드 실패 (${res.statusCode}): $detail');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> updateSettings(Map<String, dynamic> settings) async {
    final response = await _sendWithRetry(
      () => http.post(
        Uri.parse('$baseUrl/api/v1/settings'),
        headers: _headers,
        body: jsonEncode(settings),
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('설정 저장 실패');
    }
  }

  Future<void> saveCrawlType(String crawlType) async {
    try {
      await _sendWithRetry(
        () => http.post(
          Uri.parse('$baseUrl/api/v1/settings'),
          headers: _headers,
          body: jsonEncode({'crawl_type': crawlType}),
        ),
      );
    } catch (_) {}
  }

  Future<(bool, String)> startRatingBatch({
    required List<String> reportNumbers,
    required int score,
  }) async {
    final response = await _sendWithRetry(
      () => http.post(
        Uri.parse('$baseUrl/rating/start'),
        headers: {
          'X-API-Key': apiKey,
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        },
        body: {'ids': reportNumbers.join('\n'), 'score': '$score'},
      ),
      timeout: const Duration(seconds: 30),
    );
    if (response.statusCode != 200) {
      return (false, '서버 별점 요청 실패: HTTP ${response.statusCode}');
    }
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final ok = json['status']?.toString() == 'success';
      final message = json['message']?.toString() ?? '서버 응답이 비어 있습니다.';
      return (ok, message);
    } catch (_) {
      return (false, '서버 별점 응답을 해석하지 못했습니다.');
    }
  }

  Future<String?> fetchCurrentRatingLog() async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/files/download',
    ).replace(queryParameters: {'path': 'logs/current_rating.log'});
    final response = await _sendWithRetry(
      () => http.get(uri, headers: {'X-API-Key': apiKey}),
      timeout: const Duration(seconds: 20),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception('별점 로그 조회 실패: ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  String get wsBaseUrl {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return '$scheme://${uri.host}:${uri.port}';
  }
}
