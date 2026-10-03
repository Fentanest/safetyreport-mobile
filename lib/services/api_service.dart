import 'client_compatibility.dart';
import 'performance_trace.dart';
import 'server_connection_service.dart';
import 'app_prefs_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/report.dart';
import '../models/report_map.dart';
import '../models/duplicate_group.dart';
import '../models/file_item.dart';
import '../models/agency_stats.dart';
import '../models/sunwi.dart';
import 'network_retry_config.dart';
import 'server_contract.dart';
import '../models/stats_overview.dart';

class ApiFeatureUnavailableException implements Exception {
  final String message;

  const ApiFeatureUnavailableException(this.message);

  @override
  String toString() => message;
}

class DownloadedFilePayload {
  final String filename;
  final Uint8List bytes;

  const DownloadedFilePayload({required this.filename, required this.bytes});
}

class DeleteFilesResult {
  final int deletedCount;
  final List<String> errors;

  const DeleteFilesResult({required this.deletedCount, required this.errors});
}

/// DB 다운로드 진행: 받은 바이트, 전체 크기(서버가 알려 주지 않으면 null).
typedef DownloadProgress = void Function(int received, int? total);

/// 진행 중인 DB 다운로드를 끊는다(취소 버튼). 요청을 실제로 닫는다.
class DownloadCancel {
  http.Client? _client;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _client?.close();
  }
}

/// 사용자가 DB 다운로드를 취소함.
class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'DB 다운로드를 취소했습니다.';
}

class ApiService {
  final String baseUrl;
  final String apiKey;

  ApiService({required this.baseUrl, required this.apiKey});

  Map<String, String> get _headers => ServerContract.apiHeaders(apiKey);

  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() request, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await ClientCompatibility.ensure(baseUrl, apiKey);
    Object? lastError;
    for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
      try {
        final networkTimer = Stopwatch()..start();
        final response = await request().timeout(timeout);
        PerformanceTrace.record('client.http_request_and_buffer', networkTimer);
        if (response.statusCode == 409) {
          final message = ServerConnectionService.upgradeMessage(response.body);
          if (message != null) {
            ClientCompatibility.reject(baseUrl, apiKey, message);
          }
        }
        return response;
      } on SocketException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      }
      if (attempt < mobileMaxRetryAttempts) {
        await Future.delayed(const Duration(seconds: mobileRetryDelaySeconds));
      }
    }
    throw Exception('네트워크 오류 ($mobileMaxRetryAttempts회 재시도 실패): $lastError');
  }

  Future<http.StreamedResponse> _sendMultipartWithRetry(
    Uri uri,
    String filePath,
  ) async {
    await ClientCompatibility.ensure(baseUrl, apiKey);
    Object? lastError;
    for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
      try {
        final req = http.MultipartRequest('POST', uri);
        req.headers.addAll(
          ServerContract.apiHeaders(apiKey, includeJsonContentType: false),
        );
        req.files.add(await http.MultipartFile.fromPath('file', filePath));
        final response = await req.send().timeout(const Duration(minutes: 5));
        if (response.statusCode == 409) {
          final body = await http.Response.fromStream(response);
          final message = ServerConnectionService.upgradeMessage(body.body);
          if (message != null) {
            ClientCompatibility.reject(baseUrl, apiKey, message);
          }
          return http.StreamedResponse(
            Stream.value(body.bodyBytes),
            body.statusCode,
            headers: body.headers,
          );
        }
        return response;
      } on SocketException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      }
      if (attempt < mobileMaxRetryAttempts) {
        await Future.delayed(const Duration(seconds: mobileRetryDelaySeconds));
      }
    }
    throw Exception(
      '업로드 네트워크 오류 ($mobileMaxRetryAttempts회 재시도 실패): $lastError',
    );
  }

  String _filenameFromResponse(
    http.Response response, {
    required String fallback,
  }) {
    final contentDisposition = response.headers['content-disposition'];
    if (contentDisposition == null || contentDisposition.isEmpty) {
      return fallback;
    }
    final match = RegExp(
      r'filename=\"?([^\";]+)\"?',
    ).firstMatch(contentDisposition);
    if (match == null) return fallback;
    return Uri.decodeComponent(match.group(1) ?? fallback);
  }

  dynamic _decodeResponse(http.Response response) {
    final body = PerformanceTrace.sync(
      'client.http_body_utf8',
      () => utf8.decode(response.bodyBytes),
    );
    return PerformanceTrace.sync('client.json_decode', () => jsonDecode(body));
  }

  Future<DashboardStats> getSummary() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.summaryPath),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
      return PerformanceTrace.sync(
        'client.report_objects',
        () => DashboardStats.fromJson(json['data']),
      );
    } else {
      throw Exception('Failed to load summary');
    }
  }

  Future<({List<Report> reports, int total})> getReportsPage(
    String category, {
    int offset = 0,
    int limit = 200,
    String dedupe = 'canonical',
  }) async {
    if (!['traffic', 'parking', 'other'].contains(category) ||
        offset < 0 ||
        limit < 1 ||
        limit > 200) {
      throw ArgumentError('잘못된 페이지');
    }
    final uri = ServerContract.apiUri(
      baseUrl,
      '${ServerContract.reportsPath(category)}/page',
      queryParameters: {
        'offset': '$offset',
        'limit': '$limit',
        'dedupe': dedupe,
      },
    );
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        'PC 서버에 페이지 조회 기능이 없습니다. PC 서버를 업데이트하세요.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('페이지 조회 실패: ${response.statusCode}');
    }
    final body = _decodeResponse(response) as Map;
    final data = body['data'] as List;
    if (data.length > limit || body['total'] is! int) {
      throw const FormatException('페이지 계약과 다른 서버 응답');
    }
    return (
      reports: PerformanceTrace.sync(
        'client.report_objects',
        () => data
            .map(
              (r) => Report.fromJson({
                ...Map<String, dynamic>.from(r as Map),
                'category': category,
              }),
            )
            .toList(),
      ),
      total: body['total'] as int,
    );
  }

  Future<List<Report>> getReports(String category, {String? dedupe}) async {
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.reportsPath(category),
      queryParameters: (dedupe == null || dedupe.isEmpty)
          ? null
          : {'dedupe': dedupe},
    );
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
      var list = json['data'] as List? ?? [];
      final fallbackCategory = switch (category) {
        'traffic' || 'parking' || 'other' => category,
        _ => '',
      };
      return list.map((item) {
        final data = Map<String, dynamic>.from(item as Map);
        final currentCategory = data['category']?.toString().trim() ?? '';
        if (fallbackCategory.isNotEmpty && currentCategory.isEmpty) {
          data['category'] = fallbackCategory;
        }
        return Report.fromJson(data);
      }).toList();
    } else {
      throw Exception('Failed to load reports');
    }
  }

  Future<List<DuplicateGroup>> getDuplicateGroups({String? status}) async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(
          baseUrl,
          ServerContract.duplicateGroupsPath,
          queryParameters: status == null || status.isEmpty
              ? null
              : {'status': status},
        ),
        headers: _headers,
      ),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        '서버가 중복 신고 관리 API를 아직 지원하지 않습니다.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('중복 신고 그룹 조회 실패: ${response.statusCode}');
    }
    final json = _decodeResponse(response) as Map<String, dynamic>;
    final list = json['data'] as List? ?? const [];
    return list
        .map(
          (item) =>
              DuplicateGroup.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  Future<void> updateDuplicateGroup(
    String groupId, {
    String? representativeId,
    String? duplicateStatus,
    String? representativeMode,
    String? note,
  }) async {
    final response = await _sendWithRetry(
      () => http.post(
        ServerContract.apiUri(
          baseUrl,
          ServerContract.duplicateGroupPath(groupId),
        ),
        headers: _headers,
        body: jsonEncode({
          'representative_id': ?representativeId,
          'duplicate_status': ?duplicateStatus,
          'representative_mode': ?representativeMode,
          'note': ?note,
        }),
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('중복 신고 그룹 저장 실패: ${response.statusCode}');
    }
  }

  Future<Map<String, dynamic>> getEditorSchema() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.editorSchemaPath),
        headers: _headers,
      ),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        '서버가 데이터 수정 API를 아직 지원하지 않습니다.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('데이터 수정 스키마 조회 실패: ${response.statusCode}');
    }
    final json = _decodeResponse(response) as Map<String, dynamic>;
    return Map<String, dynamic>.from(json['data'] as Map);
  }

  Future<Map<String, dynamic>> getEditableRecord(
    String category,
    String recordId,
  ) async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(
          baseUrl,
          ServerContract.editorRecordPath(category, recordId),
        ),
        headers: _headers,
      ),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        '서버가 데이터 수정 API를 아직 지원하지 않습니다.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('수정 대상 조회 실패: ${response.statusCode}');
    }
    final json = _decodeResponse(response) as Map<String, dynamic>;
    return Map<String, dynamic>.from(json['data'] as Map);
  }

  Future<void> saveEditableRecord(
    String category,
    String recordId,
    Map<String, dynamic> values,
  ) async {
    final response = await _sendWithRetry(
      () => http.post(
        ServerContract.apiUri(
          baseUrl,
          ServerContract.editorRecordPath(category, recordId),
        ),
        headers: _headers,
        body: jsonEncode({'values': values}),
      ),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        '서버가 데이터 수정 API를 아직 지원하지 않습니다.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('데이터 수정 저장 실패: ${response.statusCode}');
    }
  }

  Future<List<FileItem>> getFiles(String path) async {
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.filesPath,
      queryParameters: path.isNotEmpty ? {'path': path} : null,
    );
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
      final list = json['data'] as List? ?? [];
      return list.map((i) => FileItem.fromJson(i)).toList();
    } else {
      throw Exception('파일 목록 로드 실패: ${response.statusCode}');
    }
  }

  Future<DownloadedFilePayload> downloadFile(String path) async {
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.filesDownloadPath,
      queryParameters: {'path': path},
    );
    final response = await _sendWithRetry(
      () => http.get(
        uri,
        headers: ServerContract.apiHeaders(
          apiKey,
          includeJsonContentType: false,
        ),
      ),
      timeout: const Duration(minutes: 2),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        '서버가 파일 다운로드 API를 아직 지원하지 않습니다.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('파일 다운로드 실패: ${response.statusCode}');
    }
    return DownloadedFilePayload(
      filename: _filenameFromResponse(response, fallback: path.split('/').last),
      bytes: response.bodyBytes,
    );
  }

  Future<DownloadedFilePayload> downloadFilesArchive(List<String> paths) async {
    final response = await _sendWithRetry(
      () => http.post(
        ServerContract.apiUri(baseUrl, ServerContract.filesMultiDownloadPath),
        headers: _headers,
        body: jsonEncode({'paths': paths}),
      ),
      timeout: const Duration(minutes: 2),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        '서버가 다중 파일 다운로드를 아직 지원하지 않습니다.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('다중 파일 다운로드 실패: ${response.statusCode}');
    }
    return DownloadedFilePayload(
      filename: _filenameFromResponse(
        response,
        fallback: 'safetyreport_files.zip',
      ),
      bytes: response.bodyBytes,
    );
  }

  Future<DeleteFilesResult> deleteFiles(List<String> paths) async {
    final response = await _sendWithRetry(
      () => http.post(
        ServerContract.apiUri(baseUrl, ServerContract.filesDeleteMultiPath),
        headers: _headers,
        body: jsonEncode({'paths': paths}),
      ),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        '서버가 파일 삭제 API를 아직 지원하지 않습니다.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('파일 삭제 실패: ${response.statusCode}');
    }
    final json = _decodeResponse(response) as Map<String, dynamic>;
    final rawErrors = json['errors'] as List? ?? const [];
    return DeleteFilesResult(
      deletedCount: (json['deleted_count'] as num?)?.toInt() ?? 0,
      errors: rawErrors.map((error) => error.toString()).toList(),
    );
  }

  /// 통계 요약 + 월별 추이. 구서버(엔드포인트 없음)는 [ApiFeatureUnavailableException].
  Future<StatsOverview> getStatsOverview({String? year, String? law}) async {
    final params = <String, String>{};
    if (year != null && year != 'all') params['year'] = year;
    if (law != null) params['law'] = law;
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.statsOverviewPath,
      queryParameters: params.isNotEmpty ? params : null,
    );
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        '서버가 통계 요약 API를 아직 지원하지 않습니다. 서버를 업데이트하면 요약과 월별 추이가 표시됩니다.',
      );
    }
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
      return StatsOverview.fromJson(json['data'] as Map<String, dynamic>);
    }
    throw Exception('통계 요약 로드 실패: ${response.statusCode}');
  }

  Future<AgencyStats> getStats({String? year, String? law}) async {
    final params = <String, String>{};
    if (year != null && year != 'all') params['year'] = year;
    if (law != null) params['law'] = law;
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.statsPath,
      queryParameters: params.isNotEmpty ? params : null,
    );
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
      return AgencyStats.fromJson(json['data'] as Map<String, dynamic>);
    } else {
      throw Exception('통계 로드 실패: ${response.statusCode}');
    }
  }

  Future<ReportMapPayload> getReportMapStats({
    String? year,
    String category = 'all',
    List<double>? bounds,
    double zoom = 7,
    String dedupe = 'canonical',
  }) async {
    final params = <String, String>{
      'max_points': '1024',
      'zoom': '${zoom.round().clamp(0, 19)}',
      'dedupe': dedupe,
    };
    if (bounds != null) params['bounds'] = bounds.join(',');
    if (year != null && year != 'all') params['year'] = year;
    if (category != 'all') params['category'] = category;
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.statsMapPointsPath,
      queryParameters: params.isNotEmpty ? params : null,
    );
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
      timeout: const Duration(minutes: 2),
    );
    if (response.statusCode == 404) {
      throw const ApiFeatureUnavailableException(
        'PC 서버에 범위 지도 조회 기능이 없습니다. PC 서버를 업데이트하세요.',
      );
    }
    if (response.statusCode == 200) {
      final json = _decodeResponse(response) as Map<String, dynamic>;
      final payload = ReportMapPayload.fromJson(
        json['data'] as Map<String, dynamic>,
      );
      if (payload.points.length > 1024) {
        throw const FormatException('지도 점 수 제한을 지키지 않은 서버 응답');
      }
      return payload;
    }
    throw Exception('지도 통계 로드 실패: ${response.statusCode}');
  }

  Future<GeocodeBackfillProgress> getReportMapProgress() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.statsMapProgressPath),
        headers: _headers,
      ),
      timeout: const Duration(minutes: 2),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response) as Map<String, dynamic>;
      final data = json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : const <String, dynamic>{};
      return GeocodeBackfillProgress.fromJson(data);
    }
    throw Exception('지도 진행률 로드 실패: ${response.statusCode}');
  }

  Future<ReportMapMissingPayload> getReportMapMissingGroups({
    String? year,
    String category = 'all',
  }) async {
    final params = <String, String>{};
    if (year != null && year != 'all') params['year'] = year;
    if (category != 'all') params['category'] = category;
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.statsMapMissingPath,
      queryParameters: params.isNotEmpty ? params : null,
    );
    final response = await _sendWithRetry(
      () => http.get(uri, headers: _headers),
      timeout: const Duration(minutes: 2),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response) as Map<String, dynamic>;
      final data = json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : const <String, dynamic>{};
      return ReportMapMissingPayload.fromJson(data);
    }
    throw Exception('미변환 주소 목록 로드 실패: ${response.statusCode}');
  }

  Future<SunwiPayload> getSunwiPayload() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.sunwiPayloadPath),
        headers: _headers,
      ),
      timeout: const Duration(minutes: 2),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response) as Map<String, dynamic>;
      return SunwiPayload.fromJson(json['data'] as Map<String, dynamic>);
    }
    throw Exception('신고현황 로드 실패: ${response.statusCode}');
  }

  Future<Map<String, dynamic>> exportSunwiCsv(String kind) async {
    final response = await _sendWithRetry(
      () => http.post(
        ServerContract.apiUri(baseUrl, ServerContract.sunwiExportPath(kind)),
        headers: _headers,
      ),
      timeout: const Duration(minutes: 2),
    );
    if (response.statusCode == 200) {
      return _decodeResponse(response) as Map<String, dynamic>;
    }
    throw Exception('신고현황 CSV 생성 실패: ${response.statusCode}');
  }

  Future<List<Report>> getWatchlist() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.watchlistPath),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
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
        ServerContract.apiUri(baseUrl, ServerContract.watchlistPath),
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
        ServerContract.apiUri(baseUrl, ServerContract.crawlEnqueuePath),
        headers: _headers,
        body: jsonEncode({'report_number': reportNumber}),
      ),
    );
    if (response.statusCode != 200) {
      // 서버가 이유를 주면 그대로 보인다(예: 여러 신고에 걸리는 번호 400 — 서버 감사 R8-02).
      String? detail;
      try {
        final body = _decodeResponse(response);
        if (body is Map && body['detail'] != null) {
          detail = body['detail'].toString();
        }
      } catch (_) {}
      throw Exception(detail ?? 'Failed to enqueue crawl');
    }
  }

  Future<Map<String, dynamic>> getCrawlStatus() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.crawlStatusPath),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      return _decodeResponse(response) as Map<String, dynamic>;
    }
    throw Exception('상태 확인 실패');
  }

  Future<Map<String, dynamic>> getCrawlDone() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.crawlDonePath),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      return _decodeResponse(response) as Map<String, dynamic>;
    }
    throw Exception('완료 확인 실패');
  }

  /// 서버의 업데이트 뒤 한 번 훑기 작업 진행(하단 표시줄용). 구서버(엔드포인트 없음)·오류면 null.
  Future<Map<String, dynamic>?> fetchMaintenanceStatus() async {
    try {
      final response = await http
          .get(
            ServerContract.apiUri(
              baseUrl,
              ServerContract.maintenanceStatusPath,
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json = _decodeResponse(response) as Map<String, dynamic>;
      return json['data'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchCrawlResults() async {
    // 기기별 읽은 위치(서버 결정 D-5). 구서버는 모르는 매개변수를 무시하고 예전처럼 응답한다.
    final deviceId = await deviceInstallId();
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(
          baseUrl,
          ServerContract.crawlResultsPath,
          queryParameters: {'device_id': deviceId},
        ),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
      return (json['data'] as List? ?? []).cast<Map<String, dynamic>>();
    }
    throw Exception('결과 조회 실패');
  }

  Future<Map<String, dynamic>> getCrawlConfig() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.crawlConfigPath),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
      return json['data'] as Map<String, dynamic>;
    }
    throw Exception('설정 조회 실패');
  }

  /// 크롤링 시작. 서버는 API 방식·회원 로그인만 쓴다(레거시·비회원·최소 크롤링은 2026-09-25 제거).
  Future<void> startCrawl({
    required String crawlMode,
    required String queueList,
  }) async {
    final response = await _sendWithRetry(
      () => http.post(
        ServerContract.apiUri(baseUrl, ServerContract.crawlStartPath),
        headers: _headers,
        body: jsonEncode({'crawl_mode': crawlMode, 'queue_list': queueList}),
      ),
      timeout: const Duration(minutes: 10), // 이전 공유 자료 업로드를 마친 뒤 서버 크롤링을 시작한다.
    );
    if (response.statusCode != 200) {
      final msg = _decodeResponse(response)['detail'] ?? '크롤링 시작 실패';
      throw Exception(msg);
    }
  }

  Future<void> killCrawl() async {
    final response = await _sendWithRetry(
      () => http.post(
        ServerContract.apiUri(baseUrl, ServerContract.crawlKillPath),
        headers: _headers,
      ),
    );
    if (response.statusCode != 200) {
      final msg = _decodeResponse(response)['detail'] ?? '중지 실패';
      throw Exception(msg);
    }
  }

  Future<Map<String, dynamic>> getAppConfig() async {
    final response = await _sendWithRetry(
      () => http.get(
        ServerContract.apiUri(baseUrl, ServerContract.appConfigPath),
        headers: _headers,
      ),
    );
    if (response.statusCode == 200) {
      final json = _decodeResponse(response);
      return json['data'] as Map<String, dynamic>;
    }
    throw Exception('앱 설정 조회 실패');
  }

  /// 서버 DB 를 [targetPath] 로 흘려 받는다(메모리에 통째로 두지 않는다).
  ///
  /// 예전 `downloadDb()` 는 파일 전체를 한 요청에 2분 안에 받아야 했고, 넘기면 이전 요청을 끊지 않은 채 처음부터 다시(최대 5회)
  /// 받아 느린 회선에서 같은 파일을 여럿 동시에 받다가 최대 약 10분 동안 스피너만 돌았다(1.3.5 Client DB 백업 증상).
  /// - 전체 시간 제한 대신 [idleTimeout] 동안 한 바이트도 오지 않으면 멈추고 요청을 실제로 닫는다.
  /// - 큰 파일이라 자동으로 처음부터 다시 받지 않는다(사용자가 다시 누른다).
  /// - `<targetPath>.part` 에 받다가, 끝까지 받고 크기가 `Content-Length` 와 맞을 때만 이름을 바꾼다. 실패·취소면 조각을 지운다.
  /// 반환: 받은 바이트 수.
  Future<int> downloadDbToFile(
    String targetPath, {
    DownloadProgress? onProgress,
    DownloadCancel? cancel,
    Duration idleTimeout = const Duration(seconds: 30),
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    cancel?._client = c;
    final part = File('$targetPath.part');
    IOSink? sink;
    var received = 0;
    try {
      if (cancel?.isCancelled ?? false) throw const DownloadCancelled();
      await ClientCompatibility.ensure(baseUrl, apiKey, client: c);
      final request = http.Request(
        'GET',
        ServerContract.apiUri(baseUrl, ServerContract.settingsDbPath),
      )..headers.addAll(_headers);
      final response = await c.send(request).timeout(idleTimeout);
      if (response.statusCode != 200) {
        var detail = '';
        try {
          final body = await response.stream.bytesToString().timeout(
            idleTimeout,
          );
          final j = jsonDecode(body);
          final message = ServerConnectionService.upgradeMessage(body);
          if (response.statusCode == 409 && message != null) {
            ClientCompatibility.reject(baseUrl, apiKey, message);
          }
          if (j is Map && j['detail'] != null) detail = ' ${j['detail']}';
        } on ClientCompatibilityException {
          rethrow;
        } catch (_) {}
        throw Exception('DB 다운로드 실패: ${response.statusCode}$detail');
      }
      final total = response.contentLength;
      sink = part.openWrite();
      onProgress?.call(0, total);
      await for (final chunk in response.stream.timeout(idleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total != null && received != total) {
        throw Exception(
          'DB 다운로드가 중간에 끊겼습니다(${_mb(received)} / ${_mb(total)}). 다시 시도해 주세요.',
        );
      }
      await part.rename(targetPath);
      return received;
    } on TimeoutException {
      if (cancel?.isCancelled ?? false) throw const DownloadCancelled();
      throw Exception(
        '서버에서 ${idleTimeout.inSeconds}초 동안 데이터가 오지 않아 DB 다운로드를 멈췄습니다'
        '(받은 크기 ${_mb(received)}). 네트워크 상태를 확인하고 다시 시도해 주세요.',
      );
    } catch (e) {
      if (cancel?.isCancelled ?? false) throw const DownloadCancelled();
      rethrow;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      cancel?._client = null;
      if (client == null) c.close();
    }
  }

  static String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)}MB';

  /// .db 파일을 서버에 업로드해 복원. 서버는 모바일/서버 형식 자동 감지.
  /// 반환: {status, kind, imported, backup}
  Future<Map<String, dynamic>> uploadDb(String filePath) async {
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.settingsDbUploadPath,
    );
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
        ServerContract.apiUri(baseUrl, ServerContract.settingsPath),
        headers: _headers,
        body: jsonEncode(settings),
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('설정 저장 실패');
    }
  }

  Future<(bool, String)> startRatingBatch({
    required List<String> reportNumbers,
    required int score,
    String cause = '',
  }) async {
    final response = await _sendWithRetry(
      () => http.post(
        ServerContract.apiUri(baseUrl, ServerContract.ratingStartPath),
        headers: _headers,
        body: jsonEncode({
          'report_numbers': reportNumbers,
          'score': score,
          // 공통 사유 — 서버가 capabilities 에 rating_cause 를 알릴 때만 채워진다(구서버는 이 필드를 무시)
          if (cause.isNotEmpty) 'cause': cause,
        }),
      ),
      timeout: const Duration(seconds: 30),
    );
    try {
      final json = _decodeResponse(response) as Map<String, dynamic>;
      final ok =
          response.statusCode == 200 && json['status']?.toString() == 'success';
      final message =
          json['message']?.toString() ??
          json['detail']?.toString() ??
          '서버 응답이 비어 있습니다.';
      return (ok, message);
    } catch (_) {
      if (response.statusCode == 302) {
        return (
          false,
          '서버가 로그인 페이지로 리다이렉트했습니다. 서버 별점 API가 아직 적용되지 않았을 수 있습니다.',
        );
      }
      return (false, '서버 별점 응답을 해석하지 못했습니다. (HTTP ${response.statusCode})');
    }
  }

  Future<String?> fetchCurrentRatingLog() async {
    final uri = ServerContract.apiUri(
      baseUrl,
      ServerContract.filesDownloadPath,
      queryParameters: {'path': 'logs/current_rating.log'},
    );
    final response = await _sendWithRetry(
      () => http.get(
        uri,
        headers: ServerContract.apiHeaders(
          apiKey,
          includeJsonContentType: false,
        ),
      ),
      timeout: const Duration(seconds: 20),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception('별점 로그 조회 실패: ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  String get wsBaseUrl {
    return ServerContract.wsBaseUri(baseUrl).toString();
  }
}

/// 설치마다 한 번 만드는 기기 식별자(무작위 32자리, 개인정보 아님).
Future<String> deviceInstallId() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(AppPrefsKeys.deviceInstallId);
  if (existing != null && existing.isNotEmpty) return existing;
  final random = Random.secure();
  final id = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  await prefs.setString(AppPrefsKeys.deviceInstallId, id);
  return id;
}
