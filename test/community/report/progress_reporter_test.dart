import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/community/report/progress_reporter.dart';
import 'package:safetyreport/community/report/report_env.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'report_test_support.dart';

void main() {
  late FakeNet net;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    net = FakeNet((_) => http.Response('{"protocol":1,"stored":true}', 200));
    net.install();
  });
  tearDown(ReportEnv.reset);

  Future<void> send(
    dynamic store,
    String trigger, {
    Map<String, Object?>? backfill,
    String login = 'ok',
    Map<String, Object?>? pace,
  }) => ProgressReporter.maybeSend(
    store: store,
    trigger: trigger,
    backfill: backfill ?? bf(),
    optimize: opt(),
    officialLogin: login,
    pace: pace,
  );

  test('시작 보고: 경로·헤더(apikey·Bearer, gzip 없음)·본문 모양', () async {
    final store = await openReportStore();
    await send(
      store,
      'start',
      pace: {'foreground_slices_today': 2, 'background_runs_today': 1},
    );
    expect(net.requests, hasLength(1));
    final r = net.requests.single;
    expect(r.method, 'POST');
    expect(
      r.url.toString(),
      'https://example.supabase.co/functions/v1/community-ingest/progress',
    );
    expect(r.headers['apikey'], 'sb_publishable_test');
    expect(r.headers['Authorization'], 'Bearer tok-test');
    expect(r.headers.containsKey('Content-Encoding'), isFalse);
    final body = jsonDecode(r.body) as Map;
    expect(body['contract'], 'community-progress-v1');
    expect(body['connection_id'], testConnectionId);
    expect(body['source_app'], 'safetyreport-mobile');
    expect(body['client_version'], '2.5.1');
    expect(body['pace'], {
      'foreground_slices_today': 2,
      'background_runs_today': 1,
    });
    expect(utf8.encode(r.body).length, lessThanOrEqualTo(4096));
  });

  test('연결이 없으면 보내지 않는다', () async {
    final store = await openReportStore(withContext: false);
    await send(store, 'start');
    expect(net.requests, isEmpty);
  });

  test('같은 연결 60초 안 두 번째는 보내지 않고, 60초 뒤에는 보낸다', () async {
    final store = await openReportStore();
    await send(store, 'start');
    net.advance(const Duration(seconds: 59));
    await send(
      store,
      'state_change',
      backfill: bf(state: 'uploading', phase: 'upload'),
    );
    expect(net.requests, hasLength(1));
    net.advance(const Duration(seconds: 2));
    await send(
      store,
      'state_change',
      backfill: bf(state: 'uploading', phase: 'upload'),
    );
    expect(net.requests, hasLength(2));
  });

  test('state_change 는 상태 키가 바뀐 때만(개수만 바뀐 것은 아님)', () async {
    final store = await openReportStore();
    await send(store, 'state_change');
    net.advance(const Duration(minutes: 2));
    await send(store, 'state_change', backfill: bf(stored: 50));
    expect(net.requests, hasLength(1));
    await send(
      store,
      'state_change',
      backfill: bf(reason: 'network', state: 'paused'),
    );
    expect(net.requests, hasLength(2));
    net.advance(const Duration(minutes: 2));
    await send(
      store,
      'state_change',
      backfill: bf(reason: 'network', state: 'paused'),
      login: 'manual_required',
    );
    expect(net.requests, hasLength(3));
  });

  test('periodic 은 진행 중일 때 마지막 전송 뒤 10분마다', () async {
    final store = await openReportStore();
    await send(store, 'periodic');
    expect(net.requests, hasLength(1));
    net.advance(const Duration(minutes: 9, seconds: 59));
    await send(store, 'periodic');
    expect(net.requests, hasLength(1));
    net.advance(const Duration(seconds: 2));
    await send(store, 'periodic');
    expect(net.requests, hasLength(2));
    // done 이면 periodic 은 보내지 않는다.
    net.advance(const Duration(minutes: 30));
    await send(store, 'periodic', backfill: bf(state: 'done', phase: null));
    expect(net.requests, hasLength(2));
  });

  test('daily 는 done 이 된 뒤 기기 KST 날짜당 1번', () async {
    final store = await openReportStore();
    final done = bf(state: 'done', phase: null);
    await send(store, 'daily', backfill: done);
    expect(net.requests, hasLength(1));
    net.advance(const Duration(hours: 3)); // UTC 06:00 = KST 15:00, 같은 날
    await send(store, 'daily', backfill: done);
    expect(net.requests, hasLength(1));
    net.advance(const Duration(hours: 10)); // UTC 16:00 = KST 다음 날 01:00
    await send(store, 'daily', backfill: done);
    expect(net.requests, hasLength(2));
    // 진행 중 상태에서는 daily 가 보내지 않는다.
    net.advance(const Duration(days: 1));
    await send(store, 'daily');
    expect(net.requests, hasLength(2));
  });

  test('다른 isolate(같은 community.db)가 방금 보냈으면 이쪽도 60초 규칙을 따른다', () async {
    final store = await openReportStore();
    await send(store, 'start');
    // 백그라운드 isolate 가 같은 파일을 새로 연 것과 같다: 상태는 meta 에서 읽는다.
    net.advance(const Duration(seconds: 10));
    await send(store, 'periodic');
    expect(net.requests, hasLength(1));
  });

  test('실패(429·5xx·401·네트워크)는 조용히 넘기고 재시도하지 않으며 다음 간격은 지킨다', () async {
    final store = await openReportStore();
    for (final code in [429, 500, 401, 403]) {
      net.handler = (_) => http.Response('{}', code);
      await send(store, 'start');
      net.advance(const Duration(minutes: 11));
    }
    expect(net.requests, hasLength(4));
    net.handler = (_) => throw const SocketException('down');
    await send(store, 'start');
    expect(net.requests, hasLength(5));
    // 실패는 "보낸 것"으로 치지 않아 같은 상태도 다음에 다시 시도한다.
    net.handler = (_) => http.Response('{}', 200);
    net.advance(const Duration(minutes: 11));
    await send(store, 'state_change');
    expect(net.requests, hasLength(6));
  });

  test('503 maintenance 는 결과만 기록한다(resume_at·Retry-After)', () async {
    final store = await openReportStore();
    net.handler = (_) => http.Response(
      jsonEncode({
        'error': {
          'code': 'maintenance',
          'retryable': true,
          'resume_at': '2026-10-22T06:30:00.000Z',
        },
      }),
      503,
      headers: {'retry-after': '120'},
    );
    await send(store, 'start');
    final m = await ProgressReporter.lastMaintenance(store);
    expect(m!['resume_at'], '2026-10-22T06:30:00.000Z');
    expect(m['retry_after_s'], 120);
    await ProgressReporter.clearMaintenance(store);
    expect(await ProgressReporter.lastMaintenance(store), isNull);
    // maintenance 가 아닌 503 은 기록하지 않는다.
    net.advance(const Duration(minutes: 2));
    net.handler = (_) => http.Response('{"error":{"code":"busy"}}', 503);
    await send(store, 'start');
    expect(await ProgressReporter.lastMaintenance(store), isNull);
  });

  test('토큰이 없으면 보내지 않는다', () async {
    final store = await openReportStore();
    ReportEnv.tokenOverride = () async => null;
    await send(store, 'start');
    expect(net.requests, isEmpty);
  });

  test('알 수 없는 trigger·형식 오류 본문은 보내지 않는다', () async {
    final store = await openReportStore();
    await send(store, 'whenever');
    await send(
      store,
      'start',
      backfill: {...bf(), 'reason': 'https://x.example/a b'},
    );
    expect(net.requests, isEmpty);
  });

  group('본문 검사 (progress 계약 벡터)', () {
    final vectors =
        jsonDecode(
              File(
                'test/fixtures/backfill-resume/progress_vectors.json',
              ).readAsStringSync(),
            )
            as Map;
    Map<String, Object?>? rebuild(Map body) => ProgressReporter.buildBody(
      connectionId: body['connection_id'] as String,
      platform: body['platform'] as String,
      clientVersion: body['client_version'] as String,
      backfill: Map<String, Object?>.from(body['backfill'] as Map),
      optimize: Map<String, Object?>.from(body['optimize'] as Map),
      officialLogin: body['official_login'] as String,
      pace: body['pace'] == null
          ? null
          : Map<String, Object?>.from(body['pace'] as Map),
    );

    test('모바일 정상 본문은 그대로 만들어진다', () {
      for (final c in vectors['cases'] as List) {
        if (c['body'] is! Map) continue;
        final body = c['body'] as Map;
        if (c['expect'] != 'ok' ||
            body['source_app'] != 'safetyreport-mobile') {
          continue;
        }
        expect(rebuild(body), equals(body), reason: c['name'] as String);
      }
    });

    test('형식이 틀린 상태 코드·개수·시각·reason 은 null', () {
      for (final c in vectors['cases'] as List) {
        final name = c['name'] as String;
        if (c['body'] is! Map) continue;
        final body = c['body'] as Map;
        if (c['expect'] != 'schema_invalid') continue;
        // 모바일 앱이 만들 수 있는 필드에서 틀린 경우만 대상(최상위 모르는 키·protocol 은 앱이 만들지 않는다).
        if (!const [
          'reason must be a code, not text or a URL',
          'unknown state',
          'negative count',
          'time must be UTC Z',
        ].contains(name)) {
          continue;
        }
        expect(rebuild(body), isNull, reason: name);
      }
    });

    test('pc 용 pace 가 아닌 모바일 pace 범위 밖은 null', () {
      final ok = vectors['cases'][1]['body'] as Map;
      final bad = jsonDecode(jsonEncode(ok)) as Map;
      (bad['pace'] as Map)['background_runs_today'] = -1;
      expect(rebuild(bad), isNull);
    });
  });
}
