// D2-10: 커뮤니티 계정 응답을 읽는 클라이언트 규칙 — 서버 tests/test_community_client_rules.py·auth 와 같은
// contracts/community-client(사본, MANIFEST 해시 확인)로 검사한다.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
import 'package:safetyreport/community/gate/community_client_rules.dart';
import 'package:safetyreport/community/gate/community_device_label.dart';
import 'package:safetyreport/community/gate/gate_state.dart';

const _dir = 'contracts/community-client';

Map<String, dynamic> _vectors(String name) =>
    jsonDecode(File('$_dir/vectors/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('사본이 MANIFEST 와 같다', () {
    for (final line in File('$_dir/MANIFEST.sha256').readAsLinesSync()) {
      final parts = line.split(RegExp(r'\s+'));
      final digest = sha256
          .convert(File('$_dir/${parts[1]}').readAsBytesSync())
          .toString();
      expect(digest, parts[0], reason: parts[1]);
    }
  });

  test('status DTO 정규화와 게이트 판정', () {
    final doc = _vectors('status-dto.json');
    for (final c in (doc['cases'] as List).cast<Map<String, dynamic>>()) {
      final normalized = normalizeAccountStatus(c['raw']);
      expect(normalized, c['normalized'], reason: c['name'] as String);
      final status = CommunityAccountStatus.parse(
        c['raw'] as Map<String, Object?>,
      );
      final gate = evaluateGate(
        config: 'ok',
        session: 'valid',
        status: status.toGateInput(),
        ageSeconds: 10,
      );
      expect(gate.state, c['gate'], reason: c['name'] as String);
    }
    for (final raw in doc['invalid_top_level'] as List) {
      expect(normalizeAccountStatus(raw), isNull);
    }
  });

  test('오류 분류', () async {
    for (final c
        in (_vectors('account-errors.json')['cases'] as List)
            .cast<Map<String, dynamic>>()) {
      final expected = c['expect'] as Map<String, dynamic>;
      final name = c['name'] as String;
      final client = CommunityAccountClient(
        supabaseUrl: 'https://example.invalid',
        publishableKey: 'pk',
        client: MockClient((_) async {
          if (c['transport'] != null) throw const SocketException('down');
          return http.Response.bytes(
            utf8.encode(c['body'] as String),
            c['http_status'] as int,
            headers: (c['headers'] as Map).cast<String, String>(),
          );
        }),
      );
      if (c['transport'] == null) {
        final got = classifyAccountResponse(
          c['http_status'] as int,
          c['body'] as String,
          (c['headers'] as Map).cast<String, String>(),
        );
        expect(got.success, expected['success'], reason: name);
        if (!got.success) {
          expect(
            [got.code, got.transient, got.retryAfterSeconds, got.auth],
            [
              expected['code'],
              expected['transient'],
              expected['retry_after_seconds'],
              expected['auth'],
            ],
            reason: name,
          );
        }
      }
      if (expected['success'] == true) {
        await client.status(accessToken: 't');
        continue;
      }
      try {
        await client.status(accessToken: 't');
        fail('$name: 오류여야 한다');
      } on CommunityAccountError catch (e) {
        expect(e.transient, expected['transient'], reason: name);
        if (c['transport'] == null) {
          expect(
            [e.code, e.retryAfterSeconds, e.isAuth],
            [
              expected['code'],
              expected['retry_after_seconds'],
              expected['auth'],
            ],
            reason: name,
          );
        }
      }
    }
  });

  test('기기 이름 정리 결과', () {
    for (final c
        in (_vectors('device-label.json')['cases'] as List)
            .cast<Map<String, dynamic>>()) {
      final input = c['input'];
      if (input != null && input is! String) continue;
      expect(
        CommunityDeviceLabel.normalize(input as String?),
        c['sanitized'],
        reason: jsonEncode(input),
      );
    }
  });

  test('캐시 경계와 늦은 응답', () {
    final doc = _vectors('gate-timing.json');
    expect(doc['ttl_seconds'], communityGateCacheTtl.inSeconds);
    expect(doc['fresh_max_age_seconds'], communityGateFreshMaxAge.inSeconds);
    final ok =
        (_vectors('status-dto.json')['cases'] as List).first['raw']
            as Map<String, Object?>;
    for (final c in (doc['age_cases'] as List).cast<Map<String, dynamic>>()) {
      final gate = evaluateGate(
        config: 'ok',
        session: 'valid',
        status: CommunityAccountStatus.parse(ok).toGateInput(),
        ageSeconds: (c['age'] as num).toDouble(),
        ttlSeconds: (c['ttl'] as num).toDouble(),
      );
      expect(gate.state, c['expect'], reason: jsonEncode(c));
    }
    for (final c
        in (doc['currency_cases'] as List).cast<Map<String, dynamic>>()) {
      expect(
        isCurrentResponse(
          (c['started'] as Map).cast<String, Object?>(),
          (c['now'] as Map).cast<String, Object?>(),
        ),
        c['current'],
        reason: c['name'] as String,
      );
    }
  });
}
