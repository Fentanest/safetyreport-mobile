// 계약 벡터 테스트 (네트워크 없음).
//
// contracts/community-ingest/vectors/*.json 전 case:
// observations(32) · canonical-json(5) · schedule(keys 8 + decisions 8) ·
// list_refetch(13). 기대값 수정 금지 — 불일치는 실패로 보고한다.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/canonical_json.dart';
import 'package:safetyreport/community/capture/list_refetch.dart';
import 'package:safetyreport/community/capture/observation_rules.dart';
import 'package:safetyreport/community/upload/community_schedule.dart';

Map<String, Object?> _loadVector(String name) {
  final file = File('contracts/community-ingest/vectors/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  group('observations', () {
    final doc = _loadVector('observations.json');
    final cases = (doc['cases'] as List).cast<Map<String, Object?>>();
    test('case count', () => expect(cases.length, greaterThanOrEqualTo(30)));
    for (final c in cases) {
      test('${c['name']}', () {
        final input =
            Map<String, Object?>.from(c['input'] as Map<String, Object?>);
        final payload = buildPayload(input);
        final expected =
            Map<String, Object?>.from(c['expected_payload'] as Map);
        expect(payload, equals(expected), reason: 'payload mismatch');
        expect(payloadEligible(payload), equals(c['eligible']));
        final canonical = canonicalJson(payload);
        expect(canonical, equals(c['canonical_json']));
        final sha = sha256.convert(utf8.encode(canonical)).toString();
        expect(sha, equals(c['payload_sha256']));
      });
    }
  });

  group('canonical-json', () {
    final doc = _loadVector('canonical-json.json');
    final cases = (doc['cases'] as List).cast<Map<String, Object?>>();
    for (final c in cases) {
      test('${c['name']}', () {
        expect(canonicalJson(c['value']), equals(c['canonical_json']));
        final sha = sha256
            .convert(utf8.encode(canonicalJson(c['value'])))
            .toString();
        expect(sha, equals(c['sha256']));
      });
    }
  });

  group('schedule keys', () {
    final doc = _loadVector('schedule.json');
    final keys = (doc['keys'] as List).cast<Map<String, Object?>>();
    for (final k in keys) {
      test('${k['name']}', () {
        final now = DateTime.parse(k['now'] as String);
        expect(dueKey(now), equals(k['due_key']));
        expect(nextDueAt(now).toIso8601String(),
            equals(DateTime.parse(k['next_due_at'] as String).toIso8601String()));
      });
    }
  });

  group('schedule decisions', () {
    final doc = _loadVector('schedule.json');
    final decisions =
        (doc['decisions'] as List).cast<Map<String, Object?>>();
    for (final d in decisions) {
      test('${d['name']}', () {
        final now = DateTime.parse(d['now'] as String);
        final runsRaw =
            Map<String, Object?>.from(d['runs'] as Map<String, Object?>);
        final runs = <String, Map<String, Object?>>{};
        for (final e in runsRaw.entries) {
          runs[e.key] = Map<String, Object?>.from(e.value as Map);
        }
        final expected = d['should_run'] as bool;
        expect(shouldRun(now, runs), equals(expected));
        if (d.containsKey('key')) {
          expect(dueKey(now), equals(d['key']));
        }
      });
    }
  });

  group('list_refetch', () {
    final doc = _loadVector('list_refetch.json');
    final cases = (doc['cases'] as List).cast<Map<String, Object?>>();
    test('case count is 13', () => expect(cases.length, equals(13)));
    for (final c in cases) {
      test('${c['name']}', () {
        expect(
          shouldRefetchListItem(
            inPersonalDetail: c['in_personal_detail'] as bool,
            listLabel: c['list_label'] as String?,
            detailStatusLabel: c['detail_status_label'] as String?,
            closed: c['closed'] as String?,
            supplementOpen: c['supplement_open'] as String?,
            rebuildFailedPermanent:
                (c['rebuild_failed_permanent'] as bool?) ?? false,
            failedListLabel: c['failed_list_label'] as String?,
            inCaptureRetry: (c['in_capture_retry'] as bool?) ?? false,
          ),
          equals(c['refetch']),
        );
      });
    }
  });
}
