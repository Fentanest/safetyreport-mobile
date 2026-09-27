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

// 필수 동의 정책(버전·동의문 해시·본문)은 앱에 넣어 두지 않는다 — 중앙 status.policy 와 `policy` 액션이 정본이다
// (2026-09-27, contracts/community-ingest/account-api.md). 동의문이 바뀌어도 앱을 새로 배포할 필요가 없다.

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
  // 6. 동의: state ≠ active 또는 grant 의 (버전, 동의문 해시) ≠ 중앙의 지금 정책 → consent_required.
  //    앱에 박힌 기준과 비교하지 않는다(PC services/community_gate.py decide 와 같은 규칙).
  final consent = status['consent'];
  final consentState = consent is Map ? consent['state'] : null;
  final consentPolicy = consent is Map ? consent['policy_version'] : null;
  final consentHash = consent is Map ? consent['consent_text_sha256'] : null;
  final policy = status['policy'];
  final requiredVersion = policy is Map ? policy['required_version'] : null;
  final requiredHash = policy is Map ? policy['consent_text_sha256'] : null;
  if (consentState != 'active' ||
      requiredVersion is! String ||
      requiredVersion.isEmpty ||
      requiredHash is! String ||
      requiredHash.isEmpty ||
      consentPolicy != requiredVersion ||
      consentHash != requiredHash) {
    return const GateState(state: 'consent_required', canEnter: false);
  }
  // 7. 통과.
  return GateState(
    state: 'ok',
    canEnter: true,
    verifiedAgeSeconds: ageSeconds,
  );
}
