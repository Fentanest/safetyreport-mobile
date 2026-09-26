// Report → capture 어댑터 입력 (observation.md 2절 모바일 열).
//
// progressStatus = 상세의 C_NOW 라벨(`report.result`, detail_status 기록용).
// geo 는 그 시점 geocode_cache 조회 결과(없으면 null).
import '../../models/report.dart';
import 'community_capture.dart';

export 'geocode_lookup.dart' show fetchOfficialGeocode, normalizeOfficialAddress;

/// 개인 DB 에 저장하기 전(override·별점 보강 전) 공식 값으로 어댑터 입력을 만든다.
Map<String, Object?> buildReportAdapterInput(
  Report report,
  String entryValue,
  GeocodeHit? geo,
) =>
    buildAdapterInput(
      status: report.status,
      fineInfo: report.fineInfo,
      date: report.date,
      responseDate: report.responseDate,
      agency: report.agency,
      manager: report.manager,
      carNumber: report.carNumber,
      location: report.location,
      penaltyPoints: report.penaltyPoints,
      entryValue: entryValue,
      geo: geo,
      progressStatus: report.result,
    );
