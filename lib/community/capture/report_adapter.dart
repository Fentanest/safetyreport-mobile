// Report → capture 어댑터 입력 (observation.md 2절 모바일 열).
//
// progressStatus = 상세의 C_NOW 라벨(`report.result`, detail_status 기록용).
// 좌표는 파싱한 공식 상세 응답에서 온다. 지도 wire source 값은 기존 계약을 유지한다.
import '../../models/report.dart';
import 'community_capture.dart';

/// 개인 DB 에 저장하기 전(override·별점 보강 전) 공식 값으로 어댑터 입력을 만든다.
Map<String, Object?> buildReportAdapterInput(Report report, String entryValue) {
  final lat = report.latitude;
  final lng = report.longitude;
  final located =
      lat != null &&
      lng != null &&
      lat.isFinite &&
      lng.isFinite &&
      lat >= 32 &&
      lat <= 39.5 &&
      lng >= 124 &&
      lng <= 132;
  return buildAdapterInput(
    status: report.status,
    reportNumber: report.reportNumber,
    fineInfo: report.fineInfo,
    date: report.date,
    responseDate: report.responseDate,
    agency: report.agency,
    manager: report.manager,
    carNumber: report.carNumber,
    location: report.location,
    penaltyPoints: report.penaltyPoints,
    entryValue: entryValue,
    violationLaw: report.law,
    geo: located ? GeocodeHit(status: 'ok', lat: lat, lng: lng) : null,
    progressStatus: report.result,
  );
}
