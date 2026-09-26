// UC-1 공통 판정 벡터(contracts/upload-control/vectors.json) — 서버 tests/test_upload_policy_vectors.py 와 같은 파일·같은 결과.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/upload/upload_policy.dart' as policy;

void main() {
  final folder = Directory('contracts/upload-control');
  final vectors = jsonDecode(File('${folder.path}/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final now = DateTime.parse(vectors['now'] as String);

  test('contract files match the manifest (byte-identical with the server)', () {
    for (final line in File('${folder.path}/MANIFEST.sha256').readAsLinesSync()) {
      final parts = line.split('  ');
      final digest = sha256.convert(File('${folder.path}/${parts[1]}').readAsBytesSync()).toString();
      expect(digest, parts[0], reason: parts[1]);
    }
  });

  test('backoff', () {
    for (final v in (vectors['backoff'] as List).cast<Map<String, dynamic>>()) {
      final got = policy.backoffSeconds(v['n'] as int, (v['u'] as num).toDouble());
      expect(got, closeTo((v['seconds'] as num).toDouble(), 1e-6), reason: '$v');
      expect(got, lessThanOrEqualTo(policy.backoffCapSeconds));
    }
  });

  test('retry after', () {
    for (final v in (vectors['retry_after'] as List).cast<Map<String, dynamic>>()) {
      final headers = (v['headers'] as Map).map((k, value) => MapEntry('$k', '$value'));
      expect(policy.parseRetryAfter(headers, v['body'], now), v['hint'], reason: v['name'] as String);
    }
  });

  test('retry delay', () {
    for (final v in (vectors['retry_delay'] as List).cast<Map<String, dynamic>>()) {
      expect(policy.retryDelaySeconds(v['n'] as int, (v['u'] as num).toDouble(), v['hint'] as int?),
          closeTo((v['seconds'] as num).toDouble(), 1e-6),
          reason: '$v');
    }
  });

  test('responses', () {
    for (final v in (vectors['responses'] as List).cast<Map<String, dynamic>>()) {
      final name = v['name'] as String;
      final headers = (v['headers'] as Map).map((k, value) => MapEntry('$k', '$value'));
      final body = v['body'] == null ? null : utf8.encode(v['body'] as String);
      final got = policy.interpretResponse((v['sent'] as List).cast<String>(), v['status'] as int?, headers, body, now);
      final exp = v['expect'] as Map<String, dynamic>;
      expect(got.kind, exp['kind'], reason: name);
      if (exp['kind'] == 'ack') {
        expect(got.requestId, exp['request_id'], reason: name);
        expect({for (final e in got.events.entries) e.key: e.value.outcome}, exp['events'], reason: name);
        expect(got.missing, exp['missing'], reason: name);
      } else {
        expect(got.errorClass, exp['class'], reason: name);
        expect(got.scope, exp['scope'], reason: name);
        if (exp.containsKey('hint')) expect(got.hint, exp['hint'], reason: name);
        if (exp.containsKey('code')) expect(got.code, exp['code'], reason: name);
        if (exp.containsKey('request_id')) expect(got.requestId, exp['request_id'], reason: name);
      }
    }
  });
}
