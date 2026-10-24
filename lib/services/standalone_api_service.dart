import 'official_session.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show visibleForTesting, debugPrint;
import 'package:http/http.dart' as http;
import 'network_retry_config.dart';
import 'sync_inventory.dart';
import 'standalone_auth_service.dart';

/// 안전신문고 직접 API 클라이언트 (Authorization: BEARER 토큰 사용)
/// 토큰 만료 시 자동 재로그인 후 재시도
class StandaloneApiService {
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(int start, int end)? listForTest;

  /// 마지막 목록 요청의 연도 범위(null = 전체). 연도 한정 동기화 시험이 본다.
  @visibleForTesting
  static Set<int>? lastListYears;
  @visibleForTesting
  static Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
  Function(String id)?
  detailForTest;

  @visibleForTesting
  static http.Client Function()? httpClientFactoryForTest;
  static http.Client _client() =>
      httpClientFactoryForTest?.call() ?? http.Client();

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

  /// 점수 API 응답 분류 — 서버 satisfaction_fetcher._classify_score_payload 와 같은 규칙(기술일지 A2-06).
  /// 'empty'  : result 키가 있고 값이 null/빈 객체 — 만족도 미참여 확정
  /// 'result' : 점수 자료
  /// 'unknown': 객체가 아님, result 키 없음, error 가 null 이 아님, result 가 객체가 아님 — 확인 실패(저장된 값 유지)
  @visibleForTesting
  static ({String kind, Map<String, dynamic>? result}) classifyScorePayload(
    Object? decoded,
  ) {
    if (decoded is! Map<String, dynamic> ||
        !decoded.containsKey('result') ||
        decoded['error'] != null) {
      return (kind: 'unknown', result: null);
    }
    final result = decoded['result'];
    if (result == null || (result is Map && result.isEmpty)) {
      return (kind: 'empty', result: null);
    }
    if (result is! Map<String, dynamic>) return (kind: 'unknown', result: null);
    return (kind: 'result', result: result);
  }

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

  static Future<http.Response> _ownedGet(
    Uri uri,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final client = _client();
    try {
      if (headers.containsKey('Authorization')) {
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..headers.addAll(headers);
        return await http.Response.fromStream(
          await client.send(request).timeout(timeout),
        ).timeout(timeout);
      }
      return await client.get(uri, headers: headers).timeout(timeout);
    } finally {
      client.close();
    }
  }

  static Future<http.Response?> _getPublicWithRetry(Uri uri) async {
    Object? lastError;
    for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
      try {
        return await _ownedGet(
          uri,
          _commonHeaders,
          const Duration(seconds: 10),
        );
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
        '공개 API 조회 실패 ($mobileMaxRetryAttempts회 재시도): $lastError',
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
  }) async {
    final client = _client();
    try {
      return await client
          .post(
            uri,
            headers: {
              ..._commonHeaders,
              'Content-Type':
                  'application/x-www-form-urlencoded; charset=UTF-8',
              'Origin': 'https://www.safetyreport.go.kr',
              'Referer': ?referer,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));
    } finally {
      client.close();
    }
  }

  static Map<String, String> _headers(OfficialSession session) => {
    ..._commonHeaders,
    'Authorization': 'BEARER ${session.token}',
    'Cookie': session.cookieHeader,
    'Content-Type': 'application/json',
  };

  static bool isOfficialUri(Uri uri) =>
      uri.scheme == 'https' &&
      (uri.host == 'safetyreport.go.kr' ||
          uri.host.endsWith('.safetyreport.go.kr'));

  /// 공개 사진이 인증을 요구할 때도 목록과 같은 세션 갱신·쿠키 규칙을 사용한다.
  static Future<http.Response> fetchOfficialAttachment(Uri uri) async {
    if (!isOfficialUri(uri)) throw ArgumentError('공식 사이트 주소가 아닙니다.');
    return _getWithRetry(uri);
  }

  /// 네트워크 에러(connection reset, timeout 등) 시 1초 sleep 후 최대 3회 재시도.
  /// 401 시 자동 재로그인 후 1회 재시도.
  // ── 공식 사이트 요청 속도(2026-10-24 실측) ──
  // 상세를 간격 없이 보내면 약 19건, 1초 간격 27건, 3초 간격 60건(186초) 뒤 429 `detail_rate_limited`(Retry-After 없음).
  // 막히면 60초 쉬어도 그대로, 120초 뒤 다시 받는다. 한 번에 약 40건 + 10초에 1건꼴로 차는 한도로 보인다.
  // 정확한 값에 기대지 않고 간격을 자동 조절한다: 429 면 두 배(최대 15초), 20건 연속 성공마다 15%씩 줄인다(최소 기본값).

  /// 인증 요청 사이 최소 간격(기본값). 모든 공식 API 인증 요청(목록·상세·사진)이 이 관문을 지난다.
  @visibleForTesting
  static Duration officialRequestInterval = const Duration(seconds: 3);
  static const _maxRequestInterval = Duration(seconds: 15);

  /// 429 를 받은 같은 요청을 다시 보내기 전 기다리는 시간(초). 다 쓰면 [OfficialRateLimitedException].
  /// 실측상 60초로는 풀리지 않아 2분부터 기다린다(짧게 다시 두드리면 한도만 더 쓴다).
  @visibleForTesting
  static List<int> rateLimitWaitSeconds = const [120, 180, 300];

  /// 기다리는 동안 true 면 바로 그만둔다(동기화 중지·백그라운드 마감).
  static bool Function()? abortWait;

  /// 429 로 기다릴 때 사용자에게 보일 한 줄(동기화 로그).
  static void Function(String message)? rateLimitNotice;

  @visibleForTesting
  static Future<void> Function(Duration)? sleepForTest;

  static DateTime _nextRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  static Duration? _interval;
  static int _okStreak = 0;

  static Duration get currentRequestInterval =>
      _interval ?? officialRequestInterval;

  @visibleForTesting
  static void resetPacingForTest() {
    _nextRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
    _interval = null;
    _okStreak = 0;
  }

  static Future<void> _sleep(Duration d, {bool abortable = false}) async {
    if (abortable && (abortWait?.call() ?? false)) {
      throw const OfficialRateLimitedException();
    }
    if (sleepForTest != null) return sleepForTest!(d);
    final until = DateTime.now().add(d);
    while (true) {
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) return;
      if (abortable && (abortWait?.call() ?? false)) {
        throw const OfficialRateLimitedException();
      }
      await Future<void>.delayed(
        left < const Duration(seconds: 1) ? left : const Duration(seconds: 1),
      );
    }
  }

  /// 다음 요청 자리를 먼저 잡고 기다린다 — 동시에 불려도 간격이 겹치지 않는다.
  static Future<void> _pace() async {
    final now = DateTime.now();
    final at = _nextRequestAt.isAfter(now) ? _nextRequestAt : now;
    _nextRequestAt = at.add(currentRequestInterval);
    if (at.isAfter(now)) await _sleep(at.difference(now));
  }

  static void _noteSuccess() {
    final interval = currentRequestInterval;
    if (interval <= officialRequestInterval) return;
    if (++_okStreak >= 20) {
      _okStreak = 0;
      final next = interval * 0.85;
      _interval = next < officialRequestInterval ? null : next;
    }
  }

  static void _noteLimited() {
    _okStreak = 0;
    final next = currentRequestInterval * 2;
    _interval = next > _maxRequestInterval ? _maxRequestInterval : next;
  }

  static String? _limitReason(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      final code = body is Map ? (body['reason'] ?? body['error']) : null;
      return code is String && RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(code)
          ? code
          : null;
    } catch (_) {
      return null;
    }
  }

  static Future<http.Response> _pacedGet(
    Uri uri,
    Map<String, String> headers,
  ) async {
    await _pace();
    return _ownedGet(uri, headers, const Duration(seconds: 20));
  }

  static Future<http.Response> _getWithRetry(Uri uri) async {
    var res = await _getOnce(uri);
    // 429: 같은 요청을 늘려 가며 기다렸다 다시 보낸다. 다음 신고로 넘어가며 계속 두드리지 않는다.
    for (final seconds in rateLimitWaitSeconds) {
      if (res.statusCode != 429) break;
      _noteLimited();
      debugPrint(
        '[official_api] status=429 reason=${_limitReason(res) ?? 'none'} wait=${seconds}s',
      );
      rateLimitNotice?.call(
        '안전신문고가 요청이 많다며 잠시 막았습니다. $seconds초 기다린 뒤 이어서 받습니다.',
      );
      await _sleep(Duration(seconds: seconds), abortable: true);
      res = await _getOnce(uri);
    }
    if (res.statusCode == 429) throw const OfficialRateLimitedException();
    if (res.statusCode == 200) _noteSuccess();
    return res;
  }

  static Future<http.Response> _getOnce(Uri uri) async {
    var session = await StandaloneAuthService.ensureValidSession();
    var headers = _headers(session);
    http.Response? res;

    for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
      try {
        res = await _pacedGet(uri, headers);
        break;
      } on SocketException catch (_) {
        // errno 104 (connection reset), 110 (timeout) 등 네트워크 일시 오류
      } on http.ClientException catch (_) {
      } on TimeoutException catch (_) {}
      if (attempt < mobileMaxRetryAttempts) {
        await Future.delayed(const Duration(seconds: mobileRetryDelaySeconds));
      }
    }

    if (res == null) throw const OfficialNetworkException();

    await StandaloneAuthService.updateResponseCookies(
      session,
      res.headers['set-cookie'],
    );
    if (res.statusCode == 401) {
      debugPrint(
        '[official_api] status=401 retry=0 format=${_responseFormat(res)}',
      );
      session = await StandaloneAuthService.ensureValidSession(refresh: true);
      headers = _headers(session);
      try {
        res = await _pacedGet(uri, headers);
      } catch (_) {
        debugPrint('[official_api] status=none retry=1 format=none');
        throw const OfficialNetworkException();
      }
      await StandaloneAuthService.updateResponseCookies(
        session,
        res.headers['set-cookie'],
      );
      debugPrint(
        '[official_api] status=${res.statusCode} retry=1 format=${_responseFormat(res)}'
        '${res.statusCode == 401 ? ' code=official_session_rejected' : ''}',
      );
      if (res.statusCode == 401) throw const OfficialSessionRejectedException();
    }
    return res;
  }

  static String _responseFormat(http.Response res) =>
      res.headers['content-type']?.contains('json') == true ? 'json' : 'other';

  /// 공식 목록 API 제한(2026-10-24 실측, 응답 `request_limited`): 조회 기간은 최대 1년
  /// (`list_date_range_too_large`), 한 번에 최대 50건(`list_page_size_too_large`).
  static const officialListPageLimit = 50;
  static const _listStartYear = 2014;

  /// 2014-01-01 ~ [today] 를 달력 연도 구간으로 나눈다(최신 연도 먼저 — 사이트의 최신순과 같은 이어 붙임 순서).
  /// 각 구간은 1년(365일)을 넘지 않는다. [years] 를 주면 그 연도 구간만 남긴다.
  @visibleForTesting
  static List<({String from, String to})> listWindows(
    DateTime today, {
    Set<int>? years,
  }) {
    String d(DateTime t) =>
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    return [
      for (var y = today.year; y >= _listStartYear; y--)
        if (years == null || years.contains(y))
          (from: '$y-01-01', to: y == today.year ? d(today) : '$y-12-31'),
    ];
  }

  /// 신고번호(`SPP-YYMM-…`, 접두어 없이도)의 접수 연도. 번호의 YY 는 신고일 연도와 같다(2026-10-24 실측 3,162건 전부).
  /// 12월·1월 번호는 연말·연초 경계를 대비해 이웃 연도도 넣는다. 형식이 아니면 null — 호출자는 전체 목록을 받는다.
  static Set<int>? reportNumberYears(String reportNumber) {
    final m = RegExp(
      r'^(?:SPP-)?(\d{2})(\d{2})-\d+$',
    ).firstMatch(reportNumber.trim().toUpperCase());
    if (m == null) return null;
    final year = 2000 + int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    if (month < 1 || month > 12) return null;
    return {year, if (month == 12) year + 1, if (month == 1) year - 1};
  }

  /// 구간별 전체 건수. [fetchTotalCount] 가 새로 채우고, 이어지는 페이지 조회가 행 번호를 구간에 나눌 때 쓴다.
  static ({String key, List<int> totals})? _windowTotals;

  static Future<Map<String, dynamic>> _fetchWindowPage(
    ({String from, String to}) window,
    int startRow,
    int endRow,
  ) async {
    final uri = Uri.parse('$_base/api/v1/portal/mypage/mysafereport').replace(
      queryParameters: {
        'startRowNum': '$startRow',
        'endRowNum': '$endRow',
        'C_FRM_DATE': window.from,
        'C_TO_DATE': window.to,
        'state': '',
        'seachType': 'tit',
        'C_RELATION2': '1',
        'searchKeyWord': '',
      },
    );
    final res = await _getWithRetry(uri);
    if (res.statusCode != 200) {
      String? reason;
      try {
        final body = jsonDecode(res.body);
        final code = body is Map ? (body['reason'] ?? body['error']) : null;
        // 진단용 코드만 남긴다(응답 본문은 싣지 않는다).
        if (code is String &&
            RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(code)) {
          reason = code;
        }
      } catch (_) {}
      throw Exception(
        '목록 조회 실패 (${res.statusCode})${reason == null ? '' : ' $reason'}',
      );
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<int>> _refreshWindowTotals(
    List<({String from, String to})> windows,
    String key,
  ) async {
    _windowTotals = null;
    final totals = <int>[];
    for (final window in windows) {
      totals.add(ListInventory.readTotal(await _fetchWindowPage(window, 1, 1)));
    }
    _windowTotals = (key: key, totals: totals);
    return totals;
  }

  /// 신고 목록 조회 (전체 목록의 행 번호 기준, 페이지 단위)
  /// [startRow] 1부터 시작, [endRow] 최대 200. 공식 사이트 제한 때문에 안에서 연도 구간·50건 단위로 나눠 받아
  /// 예전 한 번 조회와 같은 모양(`result` 최신순, `totalCnt` 전체 건수)으로 이어 붙인다.
  static Future<Map<String, dynamic>> fetchReportList({
    int startRow = 1,
    int endRow = 200,
    Set<int>? years,
  }) async {
    lastListYears = years;
    final injected = listForTest;
    if (injected != null) return injected(startRow, endRow);
    final windows = listWindows(DateTime.now(), years: years);
    final key = windows.map((w) => '${w.from}~${w.to}').join(',');
    final cached = _windowTotals;
    final totals = List<int>.of(
      cached != null && cached.key == key
          ? cached.totals
          : await _refreshWindowTotals(windows, key),
    );
    final rows = <dynamic>[];
    var offset = 0;
    for (var i = 0; i < windows.length; i++) {
      final from = math.max(startRow, offset + 1);
      final to = math.min(endRow, offset + totals[i]);
      for (var a = from; a <= to; a += officialListPageLimit) {
        final b = math.min(a + officialListPageLimit - 1, to);
        final data = await _fetchWindowPage(windows[i], a - offset, b - offset);
        final fresh = ListInventory.readTotal(data);
        if (fresh != totals[i]) {
          // 받는 사이 그 연도의 건수가 바뀌었다. 바뀐 전체 건수를 돌려줘 호출부의 목록 검증이 다시 받게 한다.
          _windowTotals = null;
          totals[i] = fresh;
          return {
            'result': rows,
            'totalCnt': totals.fold<int>(0, (sum, n) => sum + n),
          };
        }
        rows.addAll(data['result'] as List);
      }
      offset += totals[i];
    }
    return {'result': rows, 'totalCnt': offset};
  }

  /// 신고 상세 조회. 상세 원본(envelope 전체)도 함께 돌려준다(2026-10-17 명세 1-3).
  /// [result] 는 기존 반환값과 같은 의미(응답의 `result`, 없으면 envelope 전체) — 파서 입력은 지금처럼 result 이다.
  /// [envelope] 은 저장용 상세 원본(신고자 키 제거 전 전체) — [SyncEngine.captureAndSaveDetail] 이 같은 시점에 저장한다.
  static Future<({Map<String, dynamic> result, Map<String, dynamic> envelope})>
  fetchReportDetail(String cNo) async {
    final injected = detailForTest;
    if (injected != null) return injected(cNo);
    final uri = Uri.parse('$_base/api/v1/portal/mypage/mysafereport/$cNo');
    final res = await _getWithRetry(uri);

    if (res.statusCode != 200) {
      throw Exception('상세 조회 실패 ($cNo, ${res.statusCode})');
    }

    final envelope = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      result: (envelope['result'] as Map<String, dynamic>?) ?? envelope,
      envelope: envelope,
    );
  }

  /// 전체 신고 건수 확인 (totalCnt 필드)
  /// [years] 를 주면 그 연도 구간만 센다(DB 에 없는 신고를 찾는 연도 한정 동기화).
  static Future<int> fetchTotalCount({Set<int>? years}) async {
    lastListYears = years;
    if (listForTest != null) {
      return ListInventory.readTotal(await listForTest!(1, 1));
    }
    final windows = listWindows(DateTime.now(), years: years);
    final totals = await _refreshWindowTotals(
      windows,
      windows.map((w) => '${w.from}~${w.to}').join(','),
    );
    return totals.fold<int>(0, (sum, n) => sum + n);
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
      final payload = classifyScorePayload(jsonDecode(res.body));
      if (payload.kind == 'unknown') {
        return (score: null, cause: '', confirmed: false, exists: false);
      }
      if (payload.kind == 'empty') {
        return (score: null, cause: '', confirmed: true, exists: false);
      }
      final r = payload.result!;
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
