// 공식 주소 기준 geocode_cache 조회 (capture 입력용).
//
// geocode_cache 에는 공식 주소 해석 결과만 쓴다
// (`LocalGeocodeService._persistCacheRecord`, source='kakao').
// 사용자 수정값을 쓰는 경로는 없다(없음을 grep 으로 확인 — REQUESTS.md 보고).
// 그래도 상태·source 를 걸러 공식 결과만 읽는다. override 좌표·주소는 읽지 않는다.
import 'package:sqflite/sqflite.dart';

import 'community_capture.dart';

/// 공식 주소 정규화 키 (geocode_utils.normalizeGeocodeAddress 와 같은 규칙).
String normalizeOfficialAddress(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return '';
  return text.replaceAll(RegExp(r'\s+'), ' ');
}

/// 공식 주소로 캐시를 조회한다. 없으면 null(나중에 location_supplement).
Future<GeocodeHit?> fetchOfficialGeocode(
    DatabaseExecutor db, String officialAddress) async {
  final key = normalizeOfficialAddress(officialAddress);
  if (key.isEmpty) return null;
  try {
    final rows = await db.query(
      'geocode_cache',
      columns: ['위도', '경도', '상태'],
      where: '주소정규화 = ? AND 상태 = ? AND source = ?',
      whereArgs: [key, 'ok', 'kakao'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return GeocodeHit(
        status: 'ok', lat: rows.first['위도'], lng: rows.first['경도']);
  } catch (_) {
    return null;
  }
}
