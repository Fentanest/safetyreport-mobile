// 업로드 장애 대응 UC-1 시나리오 (요청서 §12-A) — 실제 업로더·ingest 클라이언트 + 가짜 HTTP 계층·시계·난수.
//
// PC tests/test_community_upload_control.py 와 같은 시나리오·같은 기대값(대기 시각·결과 코드·행 상태).
// HTTP 는 MockClient 가 실제 상태 코드·헤더·본문(JSON 이 아닌 것 포함)을 돌려주고, 시계는 주입, 난수는 0(백오프 = 하한).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/upload/community_schedule.dart';
import 'package:safetyreport/community/upload/community_uploader.dart';
import 'package:safetyreport/community/upload/upload_controller.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/widgets/community_upload_panel.dart' show kstLabel;

const receipt = '11111111-1111-4111-8111-111111111111';
final t0 = DateTime.utc(2026, 9, 27);
const url = 'https://example.supabase.co';
final kNs = projectNamespace(url);

const Map<String, Object?> ctxA = {
  'contributor_fingerprint': 'ffffffffffffffffffffffffffffffff',
  'connection_id': '11111111-2222-4333-8444-555555555555',
  'writer_epoch': 1,
  'dataset_key': 'dddddddddddddddd',
  'consent_grant_id': '22222222-3333-4444-8444-666666666666',
  'policy_version': '2026-09-26.1',
  'consent_text_sha256': 'h',
  'source_app': 'safetyreport-mobile',
  'source_mode': 'standalone',
};
final Map<String, Object?> ctxB = {
  ...ctxA,
  'contributor_fingerprint': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'connection_id': '99999999-2222-4333-8444-555555555555',
  'consent_grant_id': 'aaaaaaaa-3333-4444-8444-666666666666',
};

Map<String, Object?> adapter({String location = '서울특별시 중구 세종대로 110'}) => {
      'processing_status': '수용',
      'penalty_amount': '과태료: 40,000원',
      'report_date': '2026-09-01',
      'response_date': '2026-09-10',
      'processing_agency': '서울특별시 중구청',
      'person_in_charge': '홍길동',
      'car_number': '12가3456',
      'violation_location': location,
      'entry_value': '불법주정차신고',
      'penalty_points': '',
      'geocode': {'status': 'pending'},
      'progress_status': '처리완료',
    };

typedef Reply = (int, Map<String, String>, String);
typedef Responder = FutureOr<Object> Function(Map<String, dynamic> env, Map<String, String> headers);

Reply ackBody(List events, {String status = 'accepted', bool durable = true, String requestId = 'req-1', Set<String>? only}) {
  final results = <Map<String, Object?>>[];
  for (final e in events) {
    final id = (e as Map)['event_id'] as String;
    if (only != null && !only.contains(id)) continue;
    results.add({
      'event_id': id,
      'status': status,
      'durable': durable,
      'receipt_id': durable ? receipt : null,
      'projection_status': durable ? 'published' : 'not_applicable',
      if (!durable) 'error': {'code': 'deleted', 'retryable': false},
    });
  }
  return (200, const {}, jsonEncode({'protocol': 1, 'request_id': requestId, 'results': results}));
}

Reply errBody(int status, String code, {int? retryAfter, String? header}) => (
      status,
      header == null ? const {} : {'Retry-After': header},
      jsonEncode({
        'error': {
          'code': code,
          'message': 'm',
          'request_id': 'req-e',
          'retryable': status >= 429,
          'retry_after_seconds': ?retryAfter,
        }
      }),
    );

/// nextDouble 은 0(백오프 하한), nextInt 는 실제 난수(실행 id 가 겹치지 않게).
class ZeroRandom implements Random {
  static final Random _ids = Random(7); // 실행 id 가 인스턴스마다 같아지지 않게 공유
  @override
  double nextDouble() => 0.0;
  @override
  int nextInt(int max) => _ids.nextInt(max);
  @override
  bool nextBool() => false;
}

class FakeGate implements CommunityGateCheck {
  bool fresh = true;
  String? blocked;
  final invalidated = <String>[];
  @override
  Future<bool> requireFresh() async => fresh;
  @override
  String? get blockedState => fresh ? null : blocked;
  @override
  void invalidate(String reason) => invalidated.add(reason);
}

class FakeTokens implements CommunityTokenSource {
  final calls = <String?>[];
  CommunityTokenResult Function(String? rejected)? replace;
  @override
  Future<CommunityTokenResult> getAccessTokenResult({String? rejected}) async {
    calls.add(rejected);
    final o = replace;
    if (o != null) return o(rejected);
    return CommunityTokenResult(CommunityTokenStatus.ok, rejected != null ? 'tok2' : 'tok');
  }
}

class Harness {
  late CommunityStore store;
  late String path;
  DateTime now = t0;
  final requests = <(Map<String, String>, Map<String, dynamic>)>[];
  Responder responder = (env, h) => ackBody(env['events'] as List);
  final gate = FakeGate();
  final tokens = FakeTokens();

  Future<void> open() async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('sr_uc1_');
    path = '${dir.path}/community.db';
    store = await CommunityStore.open(path: path, factory: databaseFactoryFfi);
    await store.setContext(ctxA);
  }

  Future<void> restart() async {
    await CommunityStore.closeForTest(path);
    store = await CommunityStore.open(path: path, factory: databaseFactoryFfi);
  }

  Future<void> close() async {
    await CommunityStore.closeForTest(path);
    try {
      await Directory(File(path).parent.path).delete(recursive: true);
    } catch (_) {}
  }

  late final http.Client httpClient = MockClient((req) async {
    final env = jsonDecode(req.body) as Map<String, dynamic>;
    final headers = Map<String, String>.from(req.headers);
    requests.add((headers, env));
    final result = await responder(env, headers);
    if (result is Exception) throw result;
    final (status, respHeaders, body) = result as Reply;
    return http.Response.bytes(utf8.encode(body), status, headers: respHeaders);
  });

  CommunityUploader uploader({int budget = runMaxRequests, int limit = maxBodyBytes}) => CommunityUploader(
        gate: gate,
        tokens: tokens,
        appMode: () async => AppMode.standalone,
        supabaseUrl: url,
        publishableKey: 'sb_publishable_x',
        clientVersion: '1.3.5',
        httpClient: httpClient,
        openStore: () async => store,
        random: ZeroRandom(),
        now: () => now,
        sleep: (_) async {},
        requestBudget: budget,
        bodyLimit: limit,
      );

  Future<String> upload([String trigger = 'realtime']) async => (await uploader().requestCommunityUpload(trigger)).result;

  Future<String> capture(String rid, {String? location}) async {
    final c = await captureFn(
        location == null ? adapter() : adapter(location: location),
        sourceReportId: rid, trigger: 'realtime', store: store, projectNamespace: kNs);
    return c.eventId!;
  }

  Future<Map<String, Object?>?> row(String eventId) async {
    final r = await store.db.rawQuery('SELECT * FROM outbox WHERE event_id=?', [eventId]);
    return r.isEmpty ? null : r.first;
  }

  Future<Map<String, Object?>> journal(String eventId) async =>
      (await store.db.rawQuery('SELECT * FROM source_journal WHERE event_id=?', [eventId])).first;

  Future<Map<String, Object?>?> control([String kind = 'service']) async {
    final scope = kind == 'service' ? 'service:$kNs' : 'account:$kNs:${ctxA['contributor_fingerprint']}';
    final r = await store.db.rawQuery('SELECT * FROM upload_control WHERE scope=?', [scope]);
    return r.isEmpty ? null : r.first;
  }

  Future<void> resetRows() async {
    await store.db.execute('DELETE FROM upload_control');
    await store.db.execute("UPDATE outbox SET state='pending', next_retry_at=NULL, attempt_count=0");
  }

  Future<String> midnight({CommunityUploader? u}) => catchUp('os',
      store: store, runUpload: (u ?? uploader()).requestCommunityUpload, now: now, namespace: kNs);
}

const captureFn = capture;

DateTime at(Object? iso) => DateTime.parse(iso as String).toUtc();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.open();
  });
  tearDown(() async => h.close());

  // ── 수집 사본 ────────────────────────────────────────────────────────────

  test('retry sends the same captured copy and event id', () async {
    final id = await h.capture('R1');
    final stored = await h.journal(id);
    h.responder = (env, _) => errBody(503, 'busy');
    expect(await h.upload(), 'cooldown');
    h.now = t0.add(const Duration(minutes: 10));
    h.responder = (env, _) => ackBody(env['events'] as List);
    expect(await h.upload('recovery'), 'sent');
    final sent = [for (final r in h.requests) (r.$2['events'] as List).first as Map];
    expect([for (final e in sent) e['event_id']], [id, id]);
    for (final e in sent) {
      expect(canonicalJson(Map<String, Object?>.from(e['payload'] as Map)), stored['payload_json']);
      expect(e['payload_sha256'], stored['payload_sha256']);
    }
  });

  // ── 횟수·대기 ────────────────────────────────────────────────────────────

  test('attempt count and backoff grow with each real request', () async {
    final id = await h.capture('R1');
    h.responder = (env, _) => errBody(503, 'busy');
    const expected = [2.5, 5.0, 10.0]; // UC-1: 5·2^(n-1)·0.5 (u=0)
    for (var n = 1; n <= expected.length; n++) {
      expect(await h.upload('recovery'), 'cooldown');
      final row = (await h.row(id))!;
      expect((row['state'], row['attempt_count']), ('retry_wait', n));
      expect(at(row['next_retry_at']).difference(h.now), Duration(milliseconds: (expected[n - 1] * 1000).round()));
      final control = (await h.control())!;
      expect(control['consecutive_failures'], n);
      final later = [at(row['next_retry_at']), at(control['next_attempt_at'])]..sort();
      h.now = later.last.add(const Duration(seconds: 1));
    }
    expect(h.requests.length, 3, reason: '대기 중인 호출은 요청으로 세지 않는다');
  });

  test('gate block, cooldown and missing token are not attempts', () async {
    final id = await h.capture('R1');
    h.gate
      ..fresh = false
      ..blocked = 'consent_required';
    expect(await h.upload(), 'needs_consent');
    h.gate.fresh = true;
    h.tokens.replace = (_) => const CommunityTokenResult(CommunityTokenStatus.temporarilyUnavailable);
    expect(await h.upload(), 'cooldown');
    expect((await h.row(id))!['attempt_count'], 0);
    expect(h.requests, isEmpty);
  });

  // ── 혼잡 시 전체 멈춤 ─────────────────────────────────────────────────────

  test('first transient failure stops the remaining batches', () async {
    final events = [for (var i = 0; i < 25; i++) await h.capture('R$i')]; // 20 + 5
    for (final status in [429, 503, 500, 0]) {
      await h.resetRows();
      h.requests.clear();
      h.responder = status == 0
          ? (env, _) => const SocketException('down')
          : (env, _) => errBody(status, status == 429 ? 'rate_limited' : 'busy');
      expect(await h.upload('manual'), 'cooldown', reason: '$status');
      expect(h.requests.length, 1, reason: '첫 일시 장애 뒤 남은 배치를 보내지 않는다 ($status)');
      var untouched = 0;
      for (final e in events) {
        if ((await h.row(e))!['attempt_count'] == 0) untouched++;
      }
      expect(untouched, 5, reason: '$status');
    }
  });

  test('cooldown holds for every trigger and survives a restart', () async {
    await h.capture('R1');
    h.responder = (env, _) => errBody(429, 'rate_limited', retryAfter: 60, header: '60');
    expect(await h.upload(), 'cooldown');
    final account = (await h.control('account'))!;
    expect(account['state'], 'cooling_down');
    expect(at(account['next_attempt_at']).difference(h.now), const Duration(seconds: 60));
    await h.capture('R2'); // 새 수집은 로컬에만 쌓인다
    for (final trigger in ['realtime', 'manual', 'midnight', 'recovery', 'reshare']) {
      expect(await h.upload(trigger), 'cooldown', reason: trigger);
    }
    await h.restart();
    expect(await h.upload('manual'), 'cooldown');
    expect(h.requests.length, 1);
    h.now = t0.add(const Duration(seconds: 61));
    h.responder = (env, _) => ackBody(env['events'] as List);
    expect(await h.upload('recovery'), 'sent');
    expect((h.requests[1].$2['events'] as List).length, 1, reason: '복구 확인은 1건짜리 요청 하나');
    expect((await h.control('account'))!['state'], 'ready');
    expect(h.requests.length, 3, reason: '확인이 성공하면 나머지를 이어서 보낸다');
  });

  test('retry-after header, http-date, body and plain text', () async {
    final id = await h.capture('R1');
    final cases = <(Responder, int)>[
      (
        (env, _) => (
              503,
              {'Retry-After': HttpDate.format(h.now.add(const Duration(seconds: 300)))},
              '{"error":{"code":"busy","message":"m","request_id":"r","retryable":true}}'
            ),
        300000
      ),
      ((env, _) => (429, {'retry-after': '120'}, 'slow down'), 120000),
      ((env, _) => errBody(503, 'busy', retryAfter: 45, header: '90'), 90000),
      ((env, _) => (503, const <String, String>{}, '<html>busy</html>'), 2500),
    ];
    for (final (responder, waitMs) in cases) {
      await h.resetRows();
      h.responder = responder;
      expect(await h.upload(), 'cooldown');
      expect(at((await h.row(id))!['next_retry_at']).difference(h.now), Duration(milliseconds: waitMs));
    }
  });

  // ── ACK ─────────────────────────────────────────────────────────────────

  test('durable false or malformed ack is retried, never completed or dead-lettered', () async {
    final id = await h.capture('R1');
    final bodies = <Reply>[
      ackBody([
        {'event_id': id}
      ], durable: false),
      (200, const {}, jsonEncode({'protocol': 1, 'request_id': 'r', 'results': [
        {'event_id': id, 'status': 'accepted', 'receipt_id': receipt}
      ]})),
      (200, const {}, '<html>oops</html>'),
      (200, const {}, '{"protocol":2,"request_id":"r","results":[]}'),
      (500, const {}, jsonEncode({'protocol': 1, 'request_id': 'r', 'results': [
        {'event_id': id, 'status': 'accepted', 'durable': true, 'receipt_id': receipt}
      ]})),
      // 오류 응답 본문의 httpStatus 필드가 실제 상태를 덮지 않는다(예전 모바일 결함 R2)
      (503, const {}, jsonEncode({'httpStatus': 200, 'protocol': 1, 'request_id': 'r', 'results': [
        {'event_id': id, 'status': 'accepted', 'durable': true, 'receipt_id': receipt}
      ]})),
    ];
    for (final body in bodies) {
      await h.store.db.execute('DELETE FROM upload_control');
      await h.store.db.execute("UPDATE outbox SET state='pending', next_retry_at=NULL");
      h.responder = (env, _) => body;
      expect(await h.upload(), 'cooldown', reason: body.$3);
      expect((await h.row(id))!['state'], 'retry_wait', reason: body.$3);
      expect((await h.journal(id))['ack_status'], isNull, reason: body.$3);
    }
  });

  test('empty results back off instead of an immediate resend', () async {
    final id = await h.capture('R1');
    h.responder = (env, _) => (200, const <String, String>{}, '{"protocol":1,"request_id":"r","results":[]}');
    expect(await h.upload(), 'partial');
    expect(h.requests.length, 1);
    final row = (await h.row(id))!;
    expect((row['state'], row['last_error_code']), ('retry_wait', 'ack_missing'));
    expect(await h.upload(), 'not_due');
    expect(h.requests.length, 1);
  });

  test('partial ack completes only the confirmed event', () async {
    final a = await h.capture('R1');
    final b = await h.capture('R2');
    h.responder = (env, _) => ackBody(env['events'] as List, only: {b});
    expect(await h.upload(), 'partial');
    expect(await h.row(b), isNull);
    expect((await h.journal(b))['ack_status'], 'accepted');
    expect((await h.row(a))!['state'], 'retry_wait');
  });

  test('lost response after central commit resends and counts once', () async {
    final id = await h.capture('R1');
    final central = <String>{};
    h.responder = (env, _) {
      final events = env['events'] as List;
      final fresh = [for (final e in events) if (!central.contains((e as Map)['event_id'])) e];
      central.addAll([for (final e in events) (e as Map)['event_id'] as String]);
      if (fresh.isNotEmpty) return const SocketException('response lost'); // 중앙은 저장했지만 응답을 못 받음
      return ackBody(events, status: 'duplicate');
    };
    expect(await h.upload(), 'cooldown');
    h.now = t0.add(const Duration(minutes: 5));
    expect(await h.upload('recovery'), 'sent');
    expect((await h.journal(id))['ack_status'], 'duplicate');
    expect(central.length, 1);
    expect({for (final r in h.requests) ((r.$2['events'] as List).first as Map)['event_id']}, {id});
  });

  // ── 재시도 실행기·자정 ────────────────────────────────────────────────────

  test('recovery runs when the retry time comes without a new capture', () async {
    final id = await h.capture('R1');
    h.responder = (env, _) => errBody(503, 'busy');
    await h.upload();
    final due = await h.uploader().nextDueAt();
    expect(due, at((await h.control())!['next_attempt_at']));
    h.responder = (env, _) => ackBody(env['events'] as List);
    final controller = CommunityUploadController(now: () => h.now);
    controller.start(() async => h.uploader());
    await controller.idle();
    expect(h.requests.length, 1, reason: '시각 전에는 깨지 않는다');
    expect(controller.scheduledAt, due);
    h.now = due!.add(const Duration(seconds: 1));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await h.row(id) != null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    controller.stop();
    expect(await h.row(id), isNull, reason: '재시도 시각이 되면 새 수집 없이 복구한다');
  });

  test('midnight success does not block later recovery', () async {
    final first = await h.capture('R1');
    expect(await h.midnight(), 'succeeded');
    expect(await h.row(first), isNull);
    final second = await h.capture('R2');
    h.responder = (env, _) => errBody(503, 'busy');
    await h.upload();
    h.now = t0.add(const Duration(minutes: 10));
    h.responder = (env, _) => ackBody(env['events'] as List);
    final before = h.requests.length;
    expect(await h.midnight(), 'succeeded'); // 이미 끝난 key — 다시 실행하지 않는다
    expect(h.requests.length, before);
    expect(await h.upload('recovery'), 'sent');
    expect(await h.row(second), isNull);
  });

  test('midnight is not succeeded while rows wait', () async {
    await h.capture('R1');
    h.responder = (env, _) => errBody(503, 'busy');
    expect(await h.midnight(), 'deferred');
    expect(await h.midnight(), 'deferred');
    final row = (await h.store.db.rawQuery('SELECT state, deferred_reason FROM schedule_runs')).first;
    expect((row['state'], row['deferred_reason']), ('deferred', 'busy'));
  });

  // ── lease·재시작 ──────────────────────────────────────────────────────────

  test('expired in-flight is recovered but a live run is not touched', () async {
    final id = await h.capture('R1');
    await h.store.db.rawUpdate("UPDATE outbox SET state='in_flight', lease_owner='run:dead', lease_until=?",
        [isoUtc(h.now.subtract(const Duration(minutes: 5)))]);
    expect(await h.store.acquireLease('upload', 'run:other-live', const Duration(seconds: 60)), isTrue);
    expect(await h.upload(), 'busy_other_run');
    expect((await h.row(id))!['state'], 'in_flight');
    expect(h.requests, isEmpty);
    await h.store.releaseLease('upload', 'run:other-live');
    expect(await h.upload('recovery'), 'sent');
    expect(await h.row(id), isNull);
  });

  test('losing the lease mid-run stops new batches', () async {
    for (var i = 0; i < 25; i++) {
      await h.capture('R$i');
    }
    h.responder = (env, _) async {
      await h.store.db.rawUpdate("UPDATE leases SET owner='run:thief' WHERE name='upload'"); // 다른 실행이 가져감
      return ackBody(env['events'] as List);
    };
    expect(await h.upload('manual'), 'busy_other_run');
    expect(h.requests.length, 1);
  });

  test('two runners drain once', () async {
    await h.capture('R1');
    final release = Completer<void>();
    h.responder = (env, _) async {
      await release.future;
      return ackBody(env['events'] as List);
    };
    final runs = [h.upload('realtime'), h.upload('manual')];
    await Future<void>.delayed(const Duration(milliseconds: 300));
    release.complete();
    await Future.wait(runs);
    await Future<void>.delayed(const Duration(milliseconds: 300)); // 합류한 manual 의 재실행까지
    expect(h.requests.length, 1);
  });

  // ── 인증·동의 ─────────────────────────────────────────────────────────────

  test('401 forces a real refresh and resends once', () async {
    final id = await h.capture('R1');
    h.responder = (env, headers) =>
        headers['Authorization'] == 'Bearer tok2' ? ackBody(env['events'] as List) : errBody(401, 'auth_required');
    expect(await h.upload(), 'sent');
    expect([for (final r in h.requests) r.$1['Authorization']], ['Bearer tok', 'Bearer tok2']);
    expect(h.tokens.calls, contains('tok'), reason: '거절된 토큰으로 강제 갱신');
    expect((await h.journal(id))['ack_status'], 'accepted');
  });

  test('the resend after 401 keeps the interval and the lease', () async {
    await h.capture('R1');
    h.responder = (env, headers) =>
        headers['Authorization'] == 'Bearer tok2' ? ackBody(env['events'] as List) : errBody(401, 'auth_required');
    final sleeps = <(int, Duration)>[];
    var clock = 0;
    final u = CommunityUploader(
      gate: h.gate,
      tokens: h.tokens,
      appMode: () async => AppMode.standalone,
      supabaseUrl: url,
      publishableKey: 'k',
      clientVersion: '1',
      httpClient: h.httpClient,
      openStore: () async => h.store,
      random: ZeroRandom(),
      now: () => h.now,
      sleep: (d) async => sleeps.add((h.requests.length, d)),
      monotonicMs: () => clock += 10,
    );
    expect((await u.requestCommunityUpload('realtime')).result, 'sent');
    expect(sleeps.any((s) => s.$1 == 1 && s.$2 > const Duration(seconds: 1)), isTrue, reason: '$sleeps');
  });

  test('the resend after 401 stops when the lease was taken and never touches the new owner rows', () async {
    final id = await h.capture('R1');
    h.responder = (env, _) async {
      // 토큰 갱신 사이에 lease 가 만료돼 다른 실행이 lease 와 같은 행을 가져갔다
      await h.store.db.rawUpdate("UPDATE leases SET owner='run:second' WHERE name='upload'");
      await h.store.db.rawUpdate("UPDATE outbox SET lease_owner='run:second', attempt_count=attempt_count+1");
      return errBody(401, 'auth_required');
    };
    expect(await h.upload(), 'busy_other_run');
    expect(h.requests.length, 1);
    final row = (await h.row(id))!;
    expect((row['state'], row['lease_owner']), ('in_flight', 'run:second'), reason: '다른 실행 소유의 행을 덮지 않는다');
  });

  test('the resend after 401 returns only its own rows when the lease is lost', () async {
    final id = await h.capture('R1');
    h.responder = (env, _) async {
      await h.store.db.rawUpdate("UPDATE leases SET owner='run:second' WHERE name='upload'");
      return errBody(401, 'auth_required');
    };
    expect(await h.upload(), 'busy_other_run');
    expect((await h.row(id))!['state'], 'retry_wait');
  });

  test('a realtime start is promoted while an enqueue call waits', () {
    final waiting = CommunityUploader.waitingEnqueueForTest;
    expect(CommunityUploader.effectiveTrigger('realtime'), 'realtime');
    waiting['manual'] = 1;
    expect(CommunityUploader.effectiveTrigger('realtime'), 'manual');
    expect(CommunityUploader.effectiveTrigger('reshare'), 'reshare');
    waiting['midnight'] = 1;
    expect(CommunityUploader.effectiveTrigger('realtime'), 'midnight');
    waiting.clear();
  });

  test('losing the lease never touches a held suspect now owned by another run', () async {
    final bad = await h.capture('R1');
    final other = await h.capture('R2');
    h.responder = (env, _) async {
      final ids = [for (final e in env['events'] as List) (e as Map)['event_id']];
      if (ids.contains(bad)) return errBody(422, 'schema_invalid');
      // 갱신 사이 lease 만료 → 다른 실행이 lease 와 보류 행을 가져갔다
      await h.store.db.rawUpdate("UPDATE leases SET owner='run:second' WHERE name='upload'");
      await h.store.db.rawUpdate("UPDATE outbox SET lease_owner='run:second' WHERE event_id=?", [bad]);
      return errBody(401, 'auth_required');
    };
    expect(await h.upload('manual'), 'busy_other_run');
    final held = (await h.row(bad))!;
    expect((held['state'], held['lease_owner']), ('in_flight', 'run:second'));
    expect((await h.row(other))!['state'], 'retry_wait');
  });

  test('many joined manual calls share one run started after they arrived', () async {
    await h.capture('R1');
    final release = Completer<void>();
    h.responder = (env, _) async {
      await release.future;
      return ackBody(env['events'] as List);
    };
    final realtime = h.uploader().requestCommunityUpload('realtime');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final manuals = [for (var i = 0; i < 4; i++) h.uploader().requestCommunityUpload('manual')];
    await Future<void>.delayed(const Duration(milliseconds: 100));
    release.complete();
    final r = await realtime;
    final ms = await Future.wait(manuals);
    expect({for (final m in ms) m.runId}.length, 1, reason: '도착 뒤 시작한 manual 실행 하나로 합쳐진다');
    expect(ms.first.runId, isNot(r.runId));
  });

  test('a midnight run that throws is recorded failed, not left running', () async {
    await h.capture('R1');
    final state = await catchUp('os',
        store: h.store, runUpload: (_) async => throw StateError('boom'), now: h.now, namespace: kNs);
    expect(state, 'failed');
    final row = (await h.store.db.rawQuery('SELECT state, deferred_reason, lease_owner FROM schedule_runs')).single;
    expect((row['state'], row['deferred_reason'], row['lease_owner']), ('failed', 'StateError', null));
  });

  test('a joined midnight call returns its own run, not the running one', () async {
    await h.capture('R1');
    await h.store.db.execute('DELETE FROM outbox'); // outbox 밖 미ACK journal — 자정 enqueue 로만 보낼 수 있다
    await h.capture('R2');
    final release = Completer<void>();
    h.responder = (env, _) async {
      await release.future;
      return ackBody(env['events'] as List);
    };
    final realtime = h.uploader().requestCommunityUpload('realtime');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final midnight = h.uploader().requestCommunityUpload('midnight');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    release.complete();
    final r = await realtime;
    final m = await midnight;
    expect(m.runId, isNot(r.runId));
    expect(m.result, 'sent');
    expect([for (final q in h.requests) ...(q.$2['events'] as List)].length, 2, reason: '자정 실행이 outbox 밖 journal 을 보냈다');
  });

  test('two midnight catch-ups at once: one claims the key, the other defers', () async {
    await h.capture('R1');
    final release = Completer<void>();
    h.responder = (env, _) async {
      await release.future;
      return ackBody(env['events'] as List);
    };
    final a = h.midnight();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final b = await catchUp('os', store: h.store, runUpload: h.uploader().requestCommunityUpload, now: h.now, namespace: kNs);
    release.complete();
    expect(b, 'deferred', reason: '앞 실행이 lease 를 잡고 있다(같은 이유여도 owner 가 다르다)');
    expect(await a, 'succeeded');
    final row = (await h.store.db.rawQuery('SELECT state, attempts, lease_owner FROM schedule_runs')).single;
    expect((row['state'], row['attempts'], row['lease_owner']), ('succeeded', 1, null));
  });

  test('refresh network failure is offline, not auth', () async {
    final id = await h.capture('R1');
    h.tokens.replace = (rejected) => rejected != null
        ? const CommunityTokenResult(CommunityTokenStatus.temporarilyUnavailable)
        : const CommunityTokenResult(CommunityTokenStatus.ok, 'tok');
    h.responder = (env, _) => errBody(401, 'auth_required');
    expect(await h.upload(), 'cooldown');
    expect((await h.row(id))!['state'], 'retry_wait');
  });

  test('auth_required rows resume after login with the same event', () async {
    final id = await h.capture('R1');
    h.responder = (env, _) => errBody(403, 'session_revoked');
    expect(await h.upload(), 'needs_auth');
    expect((await h.row(id))!['state'], 'auth_required');
    expect((await h.journal(id))['blocked_reason'], isNull, reason: '재로그인하면 다시 보낼 수 있어야 한다');
    expect(h.gate.invalidated, contains('session_revoked'));
    h.now = t0.add(const Duration(minutes: 10));
    h.responder = (env, _) => ackBody(env['events'] as List);
    expect(await h.upload('recovery'), 'sent');
    expect(((h.requests.last.$2['events'] as List).first as Map)['event_id'], id);
  });

  test('consent revoked blocks and another account never sends old rows', () async {
    final a = await h.capture('R1');
    h.responder = (env, _) => errBody(403, 'consent_revoked');
    expect(await h.upload(), 'needs_consent');
    expect((await h.row(a))!['state'], 'blocked');
    await h.store.setContext(ctxB);
    h.responder = (env, _) => ackBody(env['events'] as List);
    expect(await h.upload('manual'), 'no_pending');
    expect(h.requests.length, 1);
  });

  // ── 크기 ─────────────────────────────────────────────────────────────────

  test('batches are split by the exact UTF-8 size of the whole envelope', () async {
    final events = [
      for (var i = 0; i < 6; i++) await h.capture('R$i', location: '서울특별시 중구 ${'가' * 190}') // 한글 3바이트
    ];
    final (base, sizes) = await h.uploader().measure(events, 'manual');
    final limit = base + 2 * sizes.reduce(max) + 1; // 정확히 2건씩 들어가는 한도
    expect(await h.uploader(limit: limit).requestCommunityUpload('manual').then((r) => r.result), 'sent');
    expect([for (final r in h.requests) (r.$2['events'] as List).length], [2, 2, 2]);
    for (final r in h.requests) {
      expect(utf8.encode(jsonEncode(r.$2)).length, lessThanOrEqualTo(limit));
    }
  });

  test('one oversize event is isolated and the next one still goes', () async {
    final big = await h.capture('R1', location: '서울특별시 ${'가' * 190}');
    final small = await h.capture('R2', location: '서울');
    final (base, sizes) = await h.uploader().measure([big, small], 'manual');
    final limit = base + sizes[1] + 5;
    expect(base + sizes[0], greaterThan(limit));
    expect((await h.uploader(limit: limit).requestCommunityUpload('manual')).result, 'partial');
    final row = (await h.row(big))!;
    expect((row['state'], row['last_error_code']), ('dead_letter', 'payload_too_large'));
    expect(row['attempt_count'], 0, reason: '보내지 않은 이벤트는 시도로 세지 않는다');
    expect(await h.row(small), isNull);
  });

  test('413 halves the batch with the same events', () async {
    final events = [for (var i = 0; i < 4; i++) await h.capture('R$i')];
    h.responder = (env, _) =>
        (env['events'] as List).length > 1 ? errBody(413, 'payload_too_large') : ackBody(env['events'] as List);
    expect(await h.upload('manual'), 'sent', reason: '이분 뒤 모두 저장됐으면 문제가 아니다(자정 key 성공)');
    final sent = [
      for (final r in h.requests)
        if ((r.$2['events'] as List).length == 1) ((r.$2['events'] as List).first as Map)['event_id'] as String
    ]..sort();
    expect(sent, [...events]..sort());
    for (final e in events) {
      expect(await h.row(e), isNull);
    }
  });

  // ── 요청 공통 오류와 이벤트 오류 구분 ──────────────────────────────────────

  test('an ambiguous 422 is pinned on one event by a control request', () async {
    final bad = await h.capture('R1');
    final good = await h.capture('R2');
    h.responder = (env, _) => (env['events'] as List).any((e) => (e as Map)['event_id'] == bad)
        ? errBody(422, 'schema_invalid')
        : ackBody(env['events'] as List);
    expect(await h.upload('manual'), 'partial');
    expect((await h.row(bad))!['state'], 'dead_letter');
    expect(await h.row(good), isNull);
  });

  test('a 422 for every event is held, not dead-lettered', () async {
    final events = [for (var i = 0; i < 3; i++) await h.capture('R$i')];
    h.responder = (env, _) => errBody(422, 'schema_invalid');
    expect(await h.upload('manual'), 'failed');
    for (final e in events) {
      expect((await h.row(e))!['state'], isIn(['retry_wait', 'pending']), reason: '공통 문제면 이벤트를 버리지 않는다');
    }
  });

  test('415 holds the batch and cools down', () async {
    final events = [for (var i = 0; i < 2; i++) await h.capture('R$i')];
    h.responder = (env, _) => (415, const <String, String>{}, '');
    expect(await h.upload('manual'), 'failed');
    expect(h.requests.length, 1);
    for (final e in events) {
      expect((await h.row(e))!['state'], 'retry_wait');
    }
    expect((await h.control())!['last_error_code'], 'unsupported_media_type');
  });

  test('a 404 HTML page or a redirect is a server problem, not a payload error', () async {
    final id = await h.capture('R1');
    for (final reply in <Reply>[(404, const {}, '<html>Not Found</html>'), (302, {'Location': 'https://x'}, '')]) {
      await h.resetRows();
      h.responder = (env, _) => reply;
      expect(await h.upload(), 'cooldown', reason: '${reply.$1}');
      expect((await h.row(id))!['state'], 'retry_wait', reason: '${reply.$1}');
    }
  });

  // ── 이전 형식·불변 필드·예산 ──────────────────────────────────────────────

  test('an old in-flight row without a lease is recovered', () async {
    final id = await h.capture('R1');
    await h.store.db.execute("UPDATE outbox SET state='in_flight', lease_owner=NULL, lease_until=NULL");
    expect(await h.upload('recovery'), 'sent');
    expect(await h.row(id), isNull);
  });

  test('an old ack without a receipt is confirmed again with the same event', () async {
    final id = await h.capture('R1');
    await h.store.db.execute('DELETE FROM outbox');
    await h.store.db.execute(
        "UPDATE source_journal SET ack_status='accepted', receipt_id='rcpt-1', acked_at='2026-09-26T00:00:00Z'");
    h.responder = (env, _) => ackBody(env['events'] as List, status: 'duplicate');
    expect(await h.upload('manual'), 'sent');
    expect(((h.requests.first.$2['events'] as List).first as Map)['event_id'], id);
    final j = await h.journal(id);
    expect((j['ack_status'], j['receipt_id']), ('duplicate', receipt));
    // 길이가 36 이어도 UUID 가 아니면 다시 확인받는다
    await h.store.db.rawUpdate('UPDATE source_journal SET receipt_id=? WHERE event_id=?', ['x' * 36, id]);
    h.requests.clear();
    expect(await h.upload('manual'), 'sent');
    expect([for (final r in h.requests) ((r.$2['events'] as List).first as Map)['event_id']], [id]);
  });

  test('a resend keeps the stored writer epoch', () async {
    await h.capture('R1');
    h.responder = (env, _) => errBody(503, 'busy');
    await h.upload();
    await h.store.setContext({...ctxA, 'writer_epoch': 2}); // 그 사이 writer 가 바뀌어도
    h.now = t0.add(const Duration(minutes: 5));
    h.responder = (env, _) => ackBody(env['events'] as List);
    await h.upload('recovery');
    expect([for (final r in h.requests) ((r.$2['events'] as List).first as Map)['writer_epoch']], [1, 1]);
  });

  test('a run stopped by its budget is more_pending and midnight is not succeeded', () async {
    for (var i = 0; i < 25; i++) {
      await h.capture('R$i');
    }
    expect(await h.midnight(u: h.uploader(budget: 1)), 'deferred');
    expect(h.requests.length, 1);
    final row = (await h.store.db.rawQuery('SELECT state, deferred_reason FROM schedule_runs')).first;
    expect((row['state'], row['deferred_reason']), ('deferred', 'more_pending'));
  });

  // ── 기록·초기화 ───────────────────────────────────────────────────────────

  test('idle runs are not recorded and failures do not touch the rebuild', () async {
    for (var i = 0; i < 5; i++) {
      expect(await h.upload(), 'no_pending');
    }
    Future<int> runs() async => (await h.store.db.rawQuery('SELECT COUNT(*) AS n FROM upload_runs')).first['n'] as int;
    expect(await runs(), 0);
    await h.store.db.execute("INSERT INTO rebuild_jobs(run_id, required_version, local_dataset_id, source_account_namespace,"
        " state, updated_at) VALUES ('rb1','v','ds','ns','completed','t')");
    await h.capture('R1');
    h.responder = (env, _) => errBody(503, 'busy');
    await h.upload();
    expect((await h.store.db.rawQuery('SELECT state FROM rebuild_jobs')).first['state'], 'completed');
    expect(await runs(), 1);
  });

  test('status shows wait reason, times and central store', () async {
    final id = await h.capture('R1');
    h.responder = (env, _) => errBody(429, 'rate_limited', header: '60');
    await h.upload();
    var status = await h.uploader().uploadStatus();
    expect(status.controlState, 'cooling_down');
    expect(status.controlReason, 'rate_limited');
    expect(kstLabel(status.nextRetryAt), '2026-09-27 09:01');
    expect(status.oldestUnsentAt, isNotNull);
    expect(status.lastCentralAckAt, isNull);
    expect(status.lastResult, 'cooldown');
    h.now = t0.add(const Duration(minutes: 2));
    h.responder = (env, _) => (200, const <String, String>{}, jsonEncode({'protocol': 1, 'request_id': 'r', 'results': [
          {'event_id': id, 'status': 'quarantined', 'durable': true, 'receipt_id': receipt, 'projection_status': 'not_applicable'}
        ]}));
    await h.upload('recovery');
    status = await h.uploader().uploadStatus();
    expect((status.quarantined, status.stored), (1, 1));
    expect(kstLabel(status.lastCentralAckAt), '2026-09-27 09:02');
  });

  test('client and demo modes never send or record', () async {
    await h.capture('R1');
    for (final (mode, demo) in [(AppMode.server, false), (AppMode.standalone, true)]) {
      final u = CommunityUploader(
        gate: h.gate,
        tokens: h.tokens,
        appMode: () async => mode,
        demoMode: () async => demo,
        supabaseUrl: url,
        publishableKey: 'k',
        clientVersion: '1',
        httpClient: h.httpClient,
        openStore: () async => h.store,
      );
      final r = await u.requestCommunityUpload('manual');
      expect((r.result, r.errorCode), ('blocked_gate', 'client_mode'));
    }
    expect(h.requests, isEmpty);
    expect((await h.store.db.rawQuery('SELECT COUNT(*) AS n FROM upload_runs')).first['n'], 0);
  });
}
