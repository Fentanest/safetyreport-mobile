// uploader 테스트: 가짜 HTTP·게이트·토큰 (네트워크 없음).
//
// B01~B05·B08·B11~B13 대응: enqueue+drain, durable ACK 삭제, 403 blocked+게이트
// 무효화, 429 Retry-After, 5xx 백오프, 같은 신고 한 요청 하나, context 불일치
// 차단(C04), Client 모드 전송 금지, projection_status 저장.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/upload/community_uploader.dart';
import 'package:safetyreport/models/app_mode.dart';

class FakeGate implements CommunityGateCheck {
  bool fresh = true;
  final List<String> invalidated = [];
  @override
  Future<bool> requireFresh() async => fresh;
  @override
  void invalidate(String reason) => invalidated.add(reason);
}

class FakeTokens implements CommunityTokenSource {
  String? token = 'tok1';
  @override
  Future<String?> getAccessToken() async => token;
}

Future<CommunityStore> openStore() async {
  sqfliteFfiInit();
  final dir = await Directory.systemTemp.createTemp('sr_t6_up_');
  final store = await CommunityStore.open(
      path: '${dir.path}/community.db', factory: databaseFactoryFfi);
  await store.setContext({
    'contributor_fingerprint': 'fp1',
    'connection_id': '11111111-1111-4111-8111-111111111111',
    'writer_epoch': 3,
    'dataset_key': 'ds1',
    'consent_grant_id': '22222222-2222-4222-8222-222222222222',
    'policy_version': '2026-09-26.1',
    'consent_text_sha256': 'abc',
    'source_app': 'safetyreport-mobile',
    'source_mode': 'standalone',
  });
  await store.setMeta('project_namespace', 'ns1');
  return store;
}

Future<void> closeStore(CommunityStore store) async {
  final path = store.path;
  await store.db.close();
  await CommunityStore.closeForTest(path);
  try {
    await Directory(File(path).parent.path).delete(recursive: true);
  } catch (_) {}
}

Map<String, Object?> adapter(String progress) => {
      'processing_status': '수용',
      'penalty_amount': '과태료: 40,000원',
      'report_date': '2026-09-01',
      'response_date': '2026-09-10',
      'processing_agency': '서울특별시 중구청',
      'person_in_charge': '홍길동',
      'car_number': '12가3456',
      'violation_location': '서울특별시 중구 세종대로 110',
      'entry_value': '불법주정차신고',
      'penalty_points': '',
      'geocode': {'status': 'pending'},
      'progress_status': progress,
    };

CommunityUploader makeUploader({
  required CommunityStore store,
  required FakeGate gate,
  required FakeTokens tokens,
  required http.Client httpClient,
  AppMode mode = AppMode.standalone,
}) =>
    CommunityUploader(
      gate: gate,
      tokens: tokens,
      appMode: () async => mode,
      supabaseUrl: 'https://example.supabase.co',
      publishableKey: 'sb_publishable_test',
      clientVersion: '1.3.5',
      httpClient: httpClient,
      openStore: () async => store,
      random: Random(1),
    );

Map<String, Object?> ackFor(String eventId, String status,
    {String projection = 'published'}) => {
      'event_id': eventId,
      'status': status,
      'durable': true,
      'receipt_id': 'rcpt-$eventId',
      'projection_status': projection,
    };

void main() {
  group('uploader', () {
    late CommunityStore store;
    late FakeGate gate;
    late FakeTokens tokens;
    setUp(() async {
      store = await openStore();
      gate = FakeGate();
      tokens = FakeTokens();
    });
    tearDown(() async => closeStore(store));

    test('B01: capture 뒤 realtime 업로드 → accepted 삭제·투영 저장', () async {
      final c = await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      final eventId = c.eventId!;
      final httpClient = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['source_app'], equals('safetyreport-mobile'));
        expect(body['source_mode'], equals('standalone'));
        expect(body['parser_version'], equals('mobile-parser-1'));
        expect((body['events'] as List).length, equals(1));
        return http.Response(
            jsonEncode({
              'protocol': 1,
              'request_id': 'req1',
              'results': [ackFor(eventId, 'accepted')],
            }),
            200);
      });
      final u = makeUploader(
          store: store, gate: gate, tokens: tokens, httpClient: httpClient);
      final result = await u.requestCommunityUpload('realtime');
      expect(result.result, equals('success'));
      final outbox = await store.db.rawQuery('SELECT * FROM outbox');
      expect(outbox, isEmpty);
      final journal = await store.db.rawQuery(
          'SELECT ack_status AS a, projection_status AS p, receipt_id AS r FROM source_journal WHERE event_id=?',
          [eventId]);
      expect(journal.first['a'], equals('accepted'));
      expect(journal.first['p'], equals('published'));
      expect(journal.first['r'], equals('rcpt-$eventId'));
      final status = await u.uploadStatus();
      expect(status.pending, equals(0));
      expect(status.lastProjection, equals('published'));
    });

    test('B02: 같은 신고 두 이벤트는 앞 ACK 뒤 다음 요청으로', () async {
      await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'manual',
          store: store, projectNamespace: 'ns1');
      // payload 가 같으면 두 번째는 이벤트 없음 → 다른 내용으로 다시.
      await capture(
          {
            ...adapter('수용'),
            'penalty_amount': '과태료: 50,000원',
          },
          sourceReportId: 'R1', trigger: 'manual',
          store: store, projectNamespace: 'ns1');
      var requestCount = 0;
      final seenPerRequest = <List<String>>[];
      final httpClient = MockClient((req) async {
        requestCount++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final events = (body['events'] as List).cast<Map<String, dynamic>>();
        final ids = events.map((e) => e['source_report_id'] as String).toList();
        seenPerRequest.add(ids);
        expect(ids.toSet().length, equals(ids.length),
            reason: '한 요청에 같은 신고 하나만');
        return http.Response(
            jsonEncode({
              'protocol': 1,
              'request_id': 'req$requestCount',
              'results': [
                for (final e in events)
                  ackFor(e['event_id'] as String, 'accepted'),
              ],
            }),
            200);
      });
      final u = makeUploader(
          store: store, gate: gate, tokens: tokens, httpClient: httpClient);
      final result = await u.requestCommunityUpload('manual');
      expect(result.result, equals('success'));
      for (final ids in seenPerRequest) {
        expect(ids.toSet().length, equals(ids.length));
      }
      final outbox = await store.db.rawQuery('SELECT * FROM outbox');
      expect(outbox, isEmpty);
    });

    test('B03: 403 consent_revoked → blocked + 게이트 무효화', () async {
      final c = await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      final httpClient = MockClient((_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'consent_revoked',
              'message': 'revoked',
              'request_id': 'req1',
              'retryable': false,
            }
          }),
          403));
      final u = makeUploader(
          store: store, gate: gate, tokens: tokens, httpClient: httpClient);
      final result = await u.requestCommunityUpload('realtime');
      expect(gate.invalidated, contains('consent_revoked'));
      final outbox = await store.db
          .rawQuery('SELECT state FROM outbox WHERE event_id=?', [c.eventId]);
      expect(outbox.first['state'], equals('blocked'));
      expect(result.result, anyOf(equals('partial'), equals('no_change')));
    });

    test('B04: 429 → Retry-After 뒤 재시도 예약', () async {
      await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      final httpClient = MockClient((_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'rate_limited',
              'message': 'slow',
              'request_id': 'req1',
              'retryable': true,
              'retry_after_seconds': 60,
            }
          }),
          429));
      final u = makeUploader(
          store: store, gate: gate, tokens: tokens, httpClient: httpClient);
      await u.requestCommunityUpload('realtime');
      final outbox =
          await store.db.rawQuery('SELECT state, next_retry_at FROM outbox');
      expect(outbox.first['state'], equals('retry_wait'));
      expect((outbox.first['next_retry_at'] as String).isNotEmpty, isTrue);
    });

    test('B05: 500 → 지수 백오프 retry_wait', () async {
      await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      final httpClient = MockClient(
          (_) async => http.Response('boom', 500));
      final u = makeUploader(
          store: store, gate: gate, tokens: tokens, httpClient: httpClient);
      await u.requestCommunityUpload('realtime');
      final outbox = await store.db
          .rawQuery('SELECT state, attempt_count FROM outbox');
      expect(outbox.first['state'], equals('retry_wait'));
      expect(outbox.first['attempt_count'], equals(1));
    });

    test('B08: conflict → dead_letter, rejected → blocked 보존', () async {
      final c1 = await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      final c2 = await capture(adapter('수용'),
          sourceReportId: 'R2', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      final httpClient = MockClient((_) async => http.Response(
          jsonEncode({
            'protocol': 1,
            'request_id': 'req1',
            'results': [
              {
                'event_id': c1.eventId,
                'status': 'conflict',
                'durable': false,
                'error': {'code': 'event_id_conflict', 'retryable': false},
              },
              {
                'event_id': c2.eventId,
                'status': 'rejected',
                'durable': false,
                'error': {'code': 'deleted', 'retryable': false},
              },
            ],
          }),
          200));
      final u = makeUploader(
          store: store, gate: gate, tokens: tokens, httpClient: httpClient);
      await u.requestCommunityUpload('realtime');
      final o1 = await store.db.rawQuery(
          'SELECT state FROM outbox WHERE event_id=?', [c1.eventId]);
      final o2 = await store.db.rawQuery(
          'SELECT state FROM outbox WHERE event_id=?', [c2.eventId]);
      expect(o1.first['state'], equals('dead_letter'));
      expect(o2.first['state'], equals('blocked'));
    });

    test('B11: 401 → 토큰 갱신 1회 재시도', () async {
      await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      var calls = 0;
      String? authed;
      final httpClient = MockClient((req) async {
        calls++;
        authed = req.headers['Authorization'];
        if (calls == 1) {
          return http.Response(
              jsonEncode({
                'error': {
                  'code': 'auth_required',
                  'message': 'expired',
                  'request_id': 'req1',
                  'retryable': false,
                }
              }),
              401);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final events = (body['events'] as List).cast<Map<String, dynamic>>();
        return http.Response(
            jsonEncode({
              'protocol': 1,
              'request_id': 'req2',
              'results': [
                for (final e in events)
                  ackFor(e['event_id'] as String, 'duplicate'),
              ],
            }),
            200);
      });
      final u = makeUploader(
          store: store, gate: gate, tokens: tokens, httpClient: httpClient);
      final result = await u.requestCommunityUpload('realtime');
      expect(calls, equals(2));
      expect(authed, equals('Bearer tok1'));
      expect(result.result, equals('success'));
    });

    test('C04: 다른 귀속 journal 은 context_mismatch 로 차단·미전송', () async {
      final c = await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      // 다른 계정으로 context 교체.
      await store.setContext({
        'contributor_fingerprint': 'fp2',
        'connection_id': '33333333-3333-4333-8333-333333333333',
        'writer_epoch': 1,
        'dataset_key': 'ds1',
        'consent_grant_id': '44444444-4444-4444-8444-444444444444',
        'policy_version': '2026-09-26.1',
        'consent_text_sha256': 'abc',
        'source_app': 'safetyreport-mobile',
        'source_mode': 'standalone',
      });
      var calls = 0;
      final httpClient = MockClient((_) async {
        calls++;
        return http.Response(
            jsonEncode({'protocol': 1, 'request_id': 'r', 'results': []}), 200);
      });
      final u = makeUploader(
          store: store, gate: gate, tokens: tokens, httpClient: httpClient);
      await u.requestCommunityUpload('recovery');
      expect(calls, equals(0));
      final outbox = await store.db.rawQuery(
          'SELECT state, last_error_code FROM outbox WHERE event_id=?',
          [c.eventId]);
      expect(outbox.first['state'], equals('blocked'));
      expect(outbox.first['last_error_code'], equals('context_mismatch'));
    });

    test('Client 모드에서는 어떤 업로드도 하지 않는다', () async {
      await capture(adapter('수용'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      var calls = 0;
      final httpClient = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      final u = makeUploader(
          store: store,
          gate: gate,
          tokens: tokens,
          httpClient: httpClient,
          mode: AppMode.server);
      final result = await u.requestCommunityUpload('manual');
      expect(calls, equals(0));
      expect(result.result, equals('no_change'));
    });

    test('projection 문구 매핑', () {
      expect(projectionMessage('published'), equals('지도 반영됨'));
      expect(projectionMessage('removed'), contains('지도에서 빠짐'));
      expect(projectionMessage('held'), contains('대기'));
      expect(projectionMessage('not_public'), contains('중앙 저장'));
      expect(projectionMessage(null), equals('전송 대기'));
    });
  });
}
