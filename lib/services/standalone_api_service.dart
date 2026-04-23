import 'dart:convert';
import 'package:http/http.dart' as http;
import 'standalone_auth_service.dart';

/// 안전신문고 직접 API 클라이언트 (Authorization: BEARER 토큰 사용)
class StandaloneApiService {
  static const _base = 'https://www.safetyreport.go.kr';

  static Future<Map<String, String>> _headers() async {
    final token = await StandaloneAuthService.getStoredToken();
    return {
      'Authorization': 'BEARER ${token ?? ''}',
      'Content-Type': 'application/json',
    };
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

    final res = await http
        .get(uri, headers: await _headers())
        .timeout(const Duration(seconds: 20));

    if (res.statusCode == 401) throw Exception('토큰 만료. 재로그인이 필요합니다.');
    if (res.statusCode != 200) throw Exception('목록 조회 실패 (${res.statusCode})');

    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// 신고 상세 조회
  static Future<Map<String, dynamic>> fetchReportDetail(String cNo) async {
    final uri = Uri.parse('$_base/api/v1/portal/mypage/mysafereport/$cNo');
    final res = await http
        .get(uri, headers: await _headers())
        .timeout(const Duration(seconds: 15));

    if (res.statusCode == 401) throw Exception('토큰 만료. 재로그인이 필요합니다.');
    if (res.statusCode != 200) throw Exception('상세 조회 실패 ($cNo, ${res.statusCode})');

    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// 전체 신고 건수 확인 (totalCnt 필드)
  static Future<int> fetchTotalCount() async {
    final data = await fetchReportList(startRow: 1, endRow: 1);
    return (data['totalCnt'] as num?)?.toInt() ?? 0;
  }
}
