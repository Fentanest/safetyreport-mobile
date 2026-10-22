// FIX-M 회귀 시험: 점검 중지·재개(R1-1·R1-4·R1-10, 결정 D4).
// R1 재현 시험(r1_pause_hot_loop·r1_early_resume_rows)의 "버그가 있다" 단언을 "고쳐졌다"로 바꿨다.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/update_requirement.dart';
import 'package:safetyreport/community/upload/upload_controller.dart';
import 'package:safetyreport/community/upload_pause.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../community/uploader_test.dart' as u;

int _nowS() => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

Future<void> _storeOverduePause(CommunityStore store, {String? message}) {
  final past = _nowS() - 30;
  return store.setMeta(
    UploadPause.metaKey,
    jsonEncode({
      'paused': true,
      'resume_at': past - 60,
      'wake_at': past,
      'message': message,
      'source': '503',
      'saved_at': past - 3600,
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommunityStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await u.openStore();
    UploadPause.resetProbeForTest();
    UploadPause.statusProbe = null;
    UploadPause.scheduleForTest = (d) async {};
    UpdateRequirement.current.value = UpdateRequirement.unlocked;
  });
  tearDown(() async {
    UploadPause.statusProbe = null;
    UploadPause.scheduleForTest = null;
    await u.closeStore(store);
  });

  test('R1-1: 재개 시각이 지났는데 중지가 남아도 업로더가 쉬지 않고 돌지 않는다(다음 시도 ≥ 60초)', () async {
    await _storeOverduePause(store);
    var runs = 0, requests = 0;
    final controller = CommunityUploadController();
    controller.start(
      () async => u.makeUploader(
        store: store,
        gate: u.FakeGate(),
        tokens: u.FakeTokens(),
        httpClient: MockClient((r) async {
          requests++;
          return http.Response('{}', 500);
        }),
        onProgress: (m) {
          if (m.contains('결과 cooldown')) runs++;
        },
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    final scheduled = controller.scheduledAt;
    controller.stop();
    expect(requests, 0);
    expect(runs, 1, reason: '2초 동안 한 번만 돌아야 한다(예전: 1000회 이상)');
    expect(scheduled, isNotNull);
    expect(
      scheduled!.difference(DateTime.now().toUtc()).inSeconds,
      greaterThanOrEqualTo(55),
    );
  });

  test('D4: 재개 시각이 지났으면 status 를 한 번 불러 보고, 풀렸으면 그대로 이어서 올린다', () async {
    await _storeOverduePause(store);
    var probes = 0;
    UploadPause.statusProbe = () async {
      probes++;
      await UploadPause.applyStatus(store, {
        'ingest': {'paused': false},
      });
    };
    final uploader = u.makeUploader(
      store: store,
      gate: u.FakeGate(),
      tokens: u.FakeTokens(),
      httpClient: MockClient((r) async => http.Response('{}', 500)),
    );
    final r = await uploader.requestCommunityUpload('recovery');
    expect(probes, 1);
    expect(r.errorCode, isNot('maintenance'));
    expect(await UploadPause.read(store), isNull);
  });

  test('D4: 확인 결과가 없거나 아직 중지면 status 는 60초에 한 번만, 다음 시도는 지금+60초', () async {
    await _storeOverduePause(store);
    var probes = 0;
    UploadPause.statusProbe = () async => probes++; // 서버가 아직 답하지 않음
    final uploader = u.makeUploader(
      store: store,
      gate: u.FakeGate(),
      tokens: u.FakeTokens(),
      httpClient: MockClient((r) async => http.Response('{}', 500)),
    );
    final first = await uploader.requestCommunityUpload('recovery');
    final second = await uploader.requestCommunityUpload('recovery');
    expect(probes, 1);
    for (final r in [first, second]) {
      expect(r.result, 'cooldown');
      expect(r.errorCode, 'maintenance');
      final next = DateTime.parse(r.nextAttemptAt!);
      expect(
        next.difference(DateTime.now().toUtc()).inSeconds,
        greaterThanOrEqualTo(55),
      );
    }
  });

  test('R1-4: 운영자가 일찍 재개하면 503 maintenance 로 묶인 행이 곧바로 올라간다', () async {
    final c = await capture(
      {...u.adapter('수용'), 'report_number': 'SPP-2609-8000002'},
      sourceReportId: 'R2',
      trigger: 'realtime',
      store: store,
      projectNamespace: u.kNs,
    );
    final resume = DateTime.now().toUtc().add(const Duration(hours: 2));
    var maintenance = true;
    var requests = 0;
    final uploader = u.makeUploader(
      store: store,
      gate: u.FakeGate(),
      tokens: u.FakeTokens(),
      httpClient: MockClient((req) async {
        requests++;
        if (maintenance) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'error': {
                  'code': 'maintenance',
                  'message': 'x',
                  'retryable': true,
                  'retry_after_seconds': 1800,
                  'resume_at': resume.toIso8601String(),
                  'pause_message': null,
                },
              }),
            ),
            503,
            headers: {'retry-after': '1800'},
          );
        }
        final env = jsonDecode(utf8.decode(req.bodyBytes)) as Map;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'protocol': env['protocol'],
              'results': [
                for (final e in env['events'] as List)
                  u.ackFor((e as Map)['event_id'] as String, 'stored'),
              ],
            }),
          ),
          200,
        );
      }),
    );
    expect((await uploader.requestCommunityUpload('manual')).result, 'cooldown');
    expect(requests, 1);
    maintenance = false;
    expect(
      await UploadPause.applyStatus(store, {
        'ingest': {'paused': false},
      }),
      'resumed',
    );
    await uploader.requestCommunityUpload('recovery');
    expect(requests, 2, reason: '재개 확인 뒤 묶였던 행을 곧바로 보낸다');
    final rows = await store.db.query(
      'outbox',
      where: 'event_id=?',
      whereArgs: [c.eventId],
    );
    // 요청이 실제로 나갔다(ACK 모양은 이 시험의 관심 밖) — 더는 점검 때문에 묶여 있지 않다.
    expect(
      rows.isEmpty || rows.single['last_error_code'] != 'maintenance',
      isTrue,
      reason: '$rows',
    );
  });

  test('R1-4: 재개 확인은 maintenance 로 미룬 행만 되돌린다(426 등 다른 대기 행은 그대로)', () async {
    final a = await capture(
      {...u.adapter('수용'), 'report_number': 'SPP-2609-8000003'},
      sourceReportId: 'R3',
      trigger: 'realtime',
      store: store,
      projectNamespace: u.kNs,
    );
    final b = await capture(
      {...u.adapter('수용'), 'report_number': 'SPP-2609-8000004'},
      sourceReportId: 'R4',
      trigger: 'realtime',
      store: store,
      projectNamespace: u.kNs,
    );
    final later = isoUtc(DateTime.now().toUtc().add(const Duration(hours: 2)));
    for (final (String? id, String code) in [
      (a.eventId, 'maintenance'),
      (b.eventId, 'client_upgrade_required'),
    ]) {
      await store.db.rawUpdate(
        "UPDATE outbox SET state='retry_wait', next_retry_at=?, last_error_code=? WHERE event_id=?",
        [later, code, id],
      );
    }
    expect(await UploadPause.releaseMaintenanceRows(store), 1);
    Future<String?> next(String id) async =>
        (await store.db.query(
              'outbox',
              where: 'event_id=?',
              whereArgs: [id],
            )).single['next_retry_at']
            as String?;
    expect((await next(a.eventId!))!.compareTo(later) < 0, isTrue);
    expect(await next(b.eventId!), later);
  });

  test('R1-10: 503 쪽 문구가 없으면 status 로 받은 운영자 문구를 지우지 않는다', () async {
    await UploadPause.applyStatus(store, {
      'ingest': {
        'paused': true,
        'resume_at': null,
        'pause_message': '서버 저장 공간을 늘리는 중입니다.',
      },
    });
    final after = await UploadPause.applyMaintenance(store, {
      'resume_at': null,
      'pause_message': null,
    });
    expect(after.message, '서버 저장 공간을 늘리는 중입니다.');
    final replaced = await UploadPause.applyMaintenance(store, {
      'resume_at': null,
      'pause_message': '새 문구',
    });
    expect(replaced.message, '새 문구');
  });
}
