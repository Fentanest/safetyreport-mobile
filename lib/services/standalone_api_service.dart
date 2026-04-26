import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'standalone_auth_service.dart';

/// 안전신문고 직접 API 클라이언트 (Authorization: BEARER 토큰 사용)
/// 토큰 만료 시 자동 재로그인 후 재시도
class StandaloneApiService {
  static const _base = 'https://www.safetyreport.go.kr';

  static const _commonHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
    'Referer': 'https://www.safetyreport.go.kr/',
    'X-Requested-With': 'XMLHttpRequest',
    'Accept': 'application/json, text/plain, */*',
  };

  /// 유효한 토큰으로 헤더 구성. 만료 시 자동 재로그인.
  static Future<Map<String, String>> _headers() async {
    final token = await StandaloneAuthService.ensureValidToken();
    return {
      ..._commonHeaders,
      'Authorization': 'BEARER $token',
      'Content-Type': 'application/json',
    };
  }

  /// 네트워크 에러(connection reset, timeout 등) 시 1초 sleep 후 최대 3회 재시도.
  /// 401 시 자동 재로그인 후 1회 재시도.
  static Future<http.Response> _getWithRetry(Uri uri) async {
    var headers = await _headers();
    http.Response? res;
    Object? lastError;

    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        res = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 20));
        break;
      } on SocketException catch (e) {
        // errno 104 (connection reset), 110 (timeout) 등 네트워크 일시 오류
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      }
      if (attempt < 3) await Future.delayed(const Duration(seconds: 1));
    }

    if (res == null) {
      throw Exception('네트워크 오류 (3회 재시도 실패): $lastError');
    }

    // 401이면 토큰 만료 — 자동 재로그인 후 1회 재시도
    if (res.statusCode == 401) {
      final newToken = await StandaloneAuthService.tryAutoRelogin();
      if (newToken != null) {
        headers = {
          ..._commonHeaders,
          'Authorization': 'BEARER $newToken',
          'Content-Type': 'application/json',
        };
        res = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 20));
      }
    }

    return res;
  }

  /// 신고 목록 조회 (페이지 단위)
  /// [startRow] 1부터 시작, [endRow] 최대 200
  static Future<Map<String, dynamic>> fetchReportList({
    int startRow = 1,
    int endRow = 200,
  }) async {
    final today = DateTime.now();
    final todayStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final uri = Uri.parse('$_base/api/v1/portal/mypage/mysafereport').replace(
      queryParameters: {
        'startRowNum': '$startRow',
        'endRowNum': '$endRow',
        'C_FRM_DATE': '2014-01-01',
        'C_TO_DATE': todayStr,
        'state': '',
        'seachType': 'tit',
        'C_RELATION2': '1',
        'searchKeyWord': '',
      },
    );

    final res = await _getWithRetry(uri);

    if (res.statusCode == 401) {
      throw const TokenExpiredException();
    }
    if (res.statusCode != 200) {
      throw Exception('목록 조회 실패 (${res.statusCode})');
    }

    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// 신고 상세 조회
  static Future<Map<String, dynamic>> fetchReportDetail(String cNo) async {
    final uri = Uri.parse('$_base/api/v1/portal/mypage/mysafereport/$cNo');
    final res = await _getWithRetry(uri);

    if (res.statusCode == 401) {
      throw const TokenExpiredException();
    }
    if (res.statusCode != 200) {
      throw Exception('상세 조회 실패 ($cNo, ${res.statusCode})');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return (json['result'] as Map<String, dynamic>?) ?? json;
  }

  /// 전체 신고 건수 확인 (totalCnt 필드)
  static Future<int> fetchTotalCount() async {
    final data = await fetchReportList(startRow: 1, endRow: 1);
    return (data['totalCnt'] as num?)?.toInt() ?? 0;
  }

  /// 만족도조사 점수+사유 조회 (인증 불필요 — 신고번호 + 휴대폰번호로 확인).
  /// 본인 휴대폰번호가 없으면 null. STSFDG_CAUSE는 불만족 사유 텍스트(빈 문자열 가능).
  /// 반환: (score: 1~5 또는 null, cause: String)
  static Future<({int? score, String cause})> fetchSatisfaction(
    String spp,
    String phone,
  ) async {
    if (phone.isEmpty || spp.isEmpty) return (score: null, cause: '');
    final uri = Uri.parse(
      '$_base/api/v1/portal/statistics/satisfactionstatistics/score/$spp/$phone',
    );
    try {
      final res = await http.get(uri, headers: _commonHeaders).timeout(
            const Duration(seconds: 10),
          );
      if (res.statusCode != 200) return (score: null, cause: '');
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final result = json['result'];
      if (result == null) return (score: null, cause: '');
      final r = result as Map<String, dynamic>;
      final scoreRaw = r['STSFDG_SCORE'];
      final score = (scoreRaw is num) ? scoreRaw.toInt() : int.tryParse('$scoreRaw') ?? 0;
      final cause = (r['STSFDG_CAUSE'] as String?) ?? '';
      return (score: score > 0 ? score : null, cause: cause.trim());
    } catch (_) {
      return (score: null, cause: '');
    }
  }
}
