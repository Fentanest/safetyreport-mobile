// Report → capture 어댑터 입력 (observation.md 2절 모바일 열).
//
// progressStatus = 상세의 C_NOW 라벨(`report.result`, detail_status 기록용).
// 좌표는 파싱한 공식 상세 응답에서 온다. 지도 wire source 값은 기존 계약을 유지한다.
import '../../models/report.dart';
import 'community_capture.dart';

/// 개인 DB 에 저장하기 전 공식 상세의 숫자 별점만 어댑터 입력에 넣는다.
///
/// [category]·[photoFirstCapture]·[photoLastCapture] 는 fine_estimate 판정용(observation-v5(fine_estimate 추가)).
/// 사진 촬영 시각은 capture 시점에 이미 아는 값만 넘긴다(새 네트워크 조회를 여기서 하지 않음) —
/// 호출자(SyncEngine)가 PC `_prefetch_derived` 와 같은 순서로 capture 전에 준비해 전달한다.
Map<String, Object?> buildReportAdapterInput(
  Report report,
  String entryValue, {
  String? category,
  String? photoFirstCapture,
  String? photoLastCapture,
}) {
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
    agencyCode: report.agencyCode,
    manager: report.manager,
    carNumber: report.carNumber,
    location: report.location,
    penaltyPoints: report.penaltyPoints,
    entryValue: entryValue,
    ssnpcCd: report.ssnpcCd,
    ssnpcType: report.ssnpcType,
    violationLaw: report.law,
    rating: report.rating,
    geo: located ? GeocodeHit(status: 'ok', lat: lat, lng: lng) : null,
    progressStatus: report.result,
    category: category,
    reportName: report.name,
    occurrenceTime: report.occurrenceTime,
    photoFirstCapture: photoFirstCapture,
    photoLastCapture: photoLastCapture,
  );
}
