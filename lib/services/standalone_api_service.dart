import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'network_retry_config.dart';
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

  static const _namedEntities = <String, String>{
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': '\u00a0',
  };

  /// HTML 엔터티 해독(숫자 &#N; &#xH; 와 흔한 이름). 서버 `html.unescape` 와 같은 결과를 내는 범위.
  @visibleForTesting
  static String decodeHtmlEntities(String text) => text.replaceAllMapped(
    RegExp(r'&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'),
    (m) {
      final body = m.group(1)!;
      if (body.startsWith('#')) {
        final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
        final code = int.tryParse(
          hex ? body.substring(2) : body.substring(1),
          radix: hex ? 16 : 10,
        );
        if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
        return String.fromCharCode(code);
      }
      return _namedEntities[body] ?? m.group(0)!;
    },
  );

  @visibleForTesting
  static String extractCauseFromPopupHtmlForTest(String html) =>
      _extractCauseFromPopupHtml(html);

  static String _extractCauseFromPopupHtml(String html) {
    final patterns = <RegExp>[
      RegExp(
        r'''id=["']STSFDG_CAUSE["'][^>]*>(.*?)</textarea>''',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'''name=["']STSFDG_CAUSE["'][^>]*>(.*?)</textarea>''',
        caseSensitive: false,
        dotAll: true,
      ),
      RegExp(
        r'''id=["']STSFDG_CAUSE["'][^>]*value=["'](.*?)["']''',
        caseSensitive: false,
        dotAll: true,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match == null) continue;
      // 서버 satisfaction_fetcher 와 같은 순서: 엔터티 해독 → 태그 제거 → 앞뒤 공백 제거
      final cause = decodeHtmlEntities(
        match.group(1) ?? '',
      ).replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (cause.isNotEmpty) return cause;
    }
    return '';
  }

  static Future<http.Response?> _getPublicWithRetry(Uri uri) async {
    Object? lastError;
    for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
      try {
        return await http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 10));
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
    if (lastError != null) {
      throw Exception(
        '공개 API 조회 실패 (${mobileMaxRetryAttempts}회 재시도): $lastError',
      );
    }
    return null;
  }

  /// 별점 제출 POST — **한 번만** 보낸다. 제출은 됐는데 응답만 끊긴 경우 다시 보내면 중복 제출이 되므로,
  /// 재시도는 호출하는 쪽(RatingService)이 사이트 점수를 먼저 확인한 뒤에만 한다(서버 star_rating_service 와 같음).
  static Future<http.Response> _postPublicFormOnce(
    Uri uri, {
    required Map<String, String> body,
    String? referer,
  }) {
    return http
        .post(
          uri,
          headers: {
            ..._commonHeaders,
            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
            'Origin': 'https://www.safetyreport.go.kr',
            if (referer != null) 'Referer': referer,
          },
          body: body,
        )
        .timeout(const Duration(seconds: 10));
  }

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

    for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
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
      if (attempt < mobileMaxRetryAttempts) {
        await Future.delayed(const Duration(seconds: mobileRetryDelaySeconds));
      }
    }

    if (res == null) {
      throw Exception(
        '네트워크 오류 (${mobileMaxRetryAttempts}회 재시도 실패): $lastError',
      );
    }

    // 401이면 토큰 만료 — 자동 재로그인 후 1회 재시도.
    // 재로그인이 안 되면 원인에 맞는 예외(재로그인 필요 / 일시 오류)를 던진다.
    if (res.statusCode == 401) {
      final newToken = StandaloneAuthService.tokenFromRelogin(
        await StandaloneAuthService.relogin(),
      );
      {
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
  /// [confirmed] 는 응답을 정상으로 받았다는 뜻(점수 없음 = 확정 미참여). 네트워크·HTTP 오류면 false.
  static Future<({int? score, String cause, bool confirmed})> fetchSatisfaction(
    String spp,
    String phone,
  ) async {
    final r = await _fetchSatisfactionDetailed(spp, phone);
    return (score: r.score, cause: r.cause, confirmed: r.confirmed);
  }

  /// [fetchSatisfaction] + [exists]: 사이트가 이 신고·번호 조합을 알고 있는가(`result` 가 비어 있지 않음).
  /// 별점 제출은 서버 star_rating_service 처럼 대상이 없으면 제출하지 않고 실패로 본다.
  static Future<({int? score, String cause, bool confirmed, bool exists})>
  _fetchSatisfactionDetailed(String spp, String phone) async {
    final normalizedPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (normalizedPhone.isEmpty || spp.isEmpty) {
      return (score: null, cause: '', confirmed: false, exists: false);
    }
    final uri = Uri.parse(
      '$_base/api/v1/portal/statistics/satisfactionstatistics/score/$spp/$normalizedPhone',
    );
    try {
      final res = await _getPublicWithRetry(uri);
      if (res == null || res.statusCode != 200) {
        return (score: null, cause: '', confirmed: false, exists: false);
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final result = json['result'];
      if (result == null || (result is Map && result.isEmpty)) {
        return (
          score: null,
          cause: '',
          confirmed: true,
          exists: false,
        ); // 서버 satisfaction_fetcher 와 같음
      }
      final r = result as Map<String, dynamic>;
      final scoreRaw = r['STSFDG_SCORE'];
      final score = (scoreRaw is num)
          ? scoreRaw.toInt()
          : int.tryParse('$scoreRaw') ?? 0;
      var cause = (r['STSFDG_CAUSE'] as String?) ?? '';
      if (score > 0 && cause.trim().isEmpty) {
        final popupUri = Uri.parse(
          '$_base/html/common/popup/comptSatisfaction.html?seq=$spp&pn=$normalizedPhone',
        );
        final popupRes = await _getPublicWithRetry(popupUri);
        if (popupRes != null && popupRes.statusCode == 200) {
          cause = _extractCauseFromPopupHtml(popupRes.body);
        }
      }
      return (
        score: score > 0 ? score : null,
        cause: cause.trim(),
        confirmed: true,
        exists: true,
      );
    } catch (_) {
      return (score: null, cause: '', confirmed: false, exists: false);
    }
  }

  static Future<void> warmUpSatisfaction() async {
    try {
      await _getPublicWithRetry(Uri.parse(_base));
    } catch (_) {}
  }

  static Future<({int? score, String cause, bool confirmed, bool exists})>
  fetchSatisfactionStatus(String spp) async {
    final phone = await StandaloneAuthService.getPhoneNumber();
    return _fetchSatisfactionDetailed(spp, phone);
  }

  static Future<void> submitSatisfaction(
    String spp, {
    required int score,
    String cause = '',
  }) async {
    final phone = await StandaloneAuthService.getPhoneNumber();
    final normalizedPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (normalizedPhone.isEmpty) {
      throw Exception('휴대폰 번호가 설정되어 있지 않습니다.');
    }
    final referer =
        '$_base/html/common/popup/satisfaction.html?seq=$spp&pn=$normalizedPhone';
    final uri = Uri.parse(
      '$_base/api/v1/portal/statistics/satisfactionstatistics',
    );
    final response = await _postPublicFormOnce(
      uri,
      referer: referer,
      body: {
        'STTEMNT_NO': spp,
        'C_PHONE2': normalizedPhone,
        'STSFDG_SCORE': '$score',
        'STSFDG_CAUSE': cause, // 공통 사유(선택) — 서버 star_rating_service 와 같은 필드
      },
    );
    if (response.statusCode != 200) {
      throw Exception('별점 제출 실패: HTTP ${response.statusCode}');
    }
  }
}
