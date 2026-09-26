// 게이트 판정 순수 함수 — 계약 벡터 전 case (`contracts/community-ingest/vectors/gate.json`).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/gate/gate_state.dart';

void main() {
  test('gate vectors: all cases pass in contract order', () {
    final vectors = jsonDecode(
      File('contracts/community-ingest/vectors/gate.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final cases = vectors['cases'] as List;
    expect(cases, isNotEmpty);
    final appVersion = vectors['app_required_policy_version'] as String;
    final ttl = (vectors['ttl_seconds'] as num).toDouble();
    for (final c in cases) {
      final m = c as Map<String, dynamic>;
      final status = m['status'] as Map<String, dynamic>?;
      final age = (m['age_seconds'] as num?)?.toDouble();
      final result = evaluateGate(
        config: m['config'] as String,
        session: m['session'] as String,
        status: status?.cast<String, Object?>(),
        ageSeconds: age,
        invalidated: (m['invalidated'] as bool?) ?? false,
        appRequiredPolicyVersion: appVersion,
        ttlSeconds: ttl,
      );
      expect(result.state, m['expect'], reason: 'case ${m['name']}');
      expect(result.canEnter, (m['expect'] as String) == 'ok', reason: 'case ${m['name']}');
    }
  });

  test('local completion flags alone never grant entry', () {
    // prefs·SQLite "완료" 값만으로는 판정을 건너뛰지 않는다 — status 없으면 verification_required.
    final result = evaluateGate(config: 'ok', session: 'valid');
    expect(result.state, 'verification_required');
    expect(result.canEnter, isFalse);
  });

  test('datasetKeyForOfficialId is normalized 64hex', () {
    final a = datasetKeyForOfficialId('User@Example.com ');
    final b = datasetKeyForOfficialId('user@example.com');
    expect(a, b);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(a), isTrue);
  });

  test('serverAccountMismatch', () {
    expect(serverAccountMismatch('aa', 'aa'), isFalse);
    expect(serverAccountMismatch('aa', 'bb'), isTrue);
    expect(serverAccountMismatch(null, 'bb'), isFalse);
    expect(serverAccountMismatch('', ''), isFalse);
  });
}
