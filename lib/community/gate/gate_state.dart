import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 필수 진입 게이트 판정 순수 함수 (`contracts/community-ingest/gate.md`).
///
/// 순서를 바꾸지 않는다. 먼저 걸린 것이 결과다.
/// 로컬 prefs·SQLite 의 "완료" 값은 이 판정을 건너뛰지 않는다.
class GateState {
  final String state;
  final bool canEnter;
  final List<String> reasons;
  final double? verifiedAgeSeconds;

  const GateState({
    required this.state,
    required this.canEnter,
    this.reasons = const [],
    this.verifiedAgeSeconds,
  });

  @override
  String toString() => 'GateState($state, canEnter=$canEnter)';
}

/// 앱이 아는 필수 동의 정책 버전 (계약 `account-api.md` status 예시와 동일).
const String communityRequiredPolicyVersion = '2026-09-26.1';

/// 게이트 캐시 유효 기간 (화면 이동용 10분).
const Duration communityGateCacheTtl = Duration(seconds: 600);

/// 새 작업(크롤 시작·업로드·초기화·설정 저장·자정 실행) 전 검증 상한 60초.
const Duration communityGateFreshMaxAge = Duration(seconds: 60);

/// 공식 로그인 ID → `dataset_key` (`account-api.md`: 클라이언트 주장값).
String datasetKeyForOfficialId(String officialId) {
  final normalized = officialId.trim().toLowerCase();
  return sha256.convert(utf8.encode('safetyreport-dataset|v1|$normalized')).toString();
}

/// Client 모드: 폰 계정 fingerprint 와 서버 연결 계정 fingerprint 비교.
bool serverAccountMismatch(String? phoneFingerprint, String? serverFingerprint) {
  if (phoneFingerprint == null ||
      phoneFingerprint.isEmpty ||
      serverFingerprint == null ||
      serverFingerprint.isEmpty) {
    return false;
  }
  return phoneFingerprint != serverFingerprint;
}

GateState evaluateGate({
  required String config,
  required String session,
  Map<String, Object?>? status,
  double? ageSeconds,
  bool invalidated = false,
  String appRequiredPolicyVersion = communityRequiredPolicyVersion,
  double ttlSeconds = 600,
}) {
  // 1. config ≠ ok → config_invalid (fail-closed).
  if (config != 'ok') {
    return const GateState(state: 'config_invalid', canEnter: false);
  }
  // 2. 세션.
  if (session == 'none') {
    return const GateState(state: 'kakao_required', canEnter: false);
  }
  if (session == 'reauth_required') {
    return const GateState(state: 'kakao_reauth_required', canEnter: false);
  }
  if (session == 'unreadable') {
    return const GateState(state: 'session_unreadable', canEnter: false);
  }
  // 3. status 없음·무효화·만료 → verification_required.
  if (status == null ||
      invalidated ||
      ageSeconds == null ||
      ageSeconds > ttlSeconds) {
    return const GateState(
      state: 'verification_required',
      canEnter: false,
    );
  }
  final gate = status['gate'];
  final kakao = gate is Map ? gate['kakao'] : null;
  // 4. status.gate.kakao = false → kakao_required.
  if (kakao != true) {
    return const GateState(state: 'kakao_required', canEnter: false);
  }
  // 5. contributor 가 active·none 이 아니면 suspended.
  final contributor = status['contributor'];
  final contributorStatus = contributor is Map ? contributor['status'] : null;
  if (contributorStatus != 'active' && contributorStatus != 'none') {
    return const GateState(state: 'suspended', canEnter: false);
  }
  // 6. 동의: state ≠ active 또는 정책 버전 불일치 → consent_required.
  final consent = status['consent'];
  final consentState = consent is Map ? consent['state'] : null;
  final consentPolicy = consent is Map ? consent['policy_version'] : null;
  if (consentState != 'active' || consentPolicy != appRequiredPolicyVersion) {
    return const GateState(state: 'consent_required', canEnter: false);
  }
  // 7. 통과.
  return GateState(
    state: 'ok',
    canEnter: true,
    verifiedAgeSeconds: ageSeconds,
  );
}
