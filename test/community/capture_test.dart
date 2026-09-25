// capture 트랜잭션·event 결정·server_completed·삭제·reshare 테스트 (네트워크 없음).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/capture/capture_retry_store.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/reshare.dart';
import 'package:safetyreport/community/capture/server_completed.dart';
import 'package:safetyreport/community/community_store.dart';

Map<String, Object?> adapter({
  String status = '수용',
  String fine = '과태료: 40,000원',
  String progress = '수용',
  Map<String, Object?>? geo,
}) =>
    {
      'processing_status': status,
      'penalty_amount': fine,
      'report_date': '2026-09-01',
      'response_date': '2026-09-10',
      'processing_agency': '서울특별시 중구청',
      'person_in_charge': '홍길동',
      'car_number': '12가3456',
      'violation_location': '서울특별시 중구 세종대로 110',
      'entry_value': '불법주정차신고',
      'penalty_points': '',
      'geocode': geo ?? {'status': 'pending'},
      'progress_status': progress,
    };

Future<CommunityStore> openTestStore() async {
  sqfliteFfiInit();
  final dir = await Directory.systemTemp.createTemp('sr_t6_capture_');
  final path = '${dir.path}/community.db';
  final store = await CommunityStore.open(
      path: path, factory: databaseFactoryFfi);
  await store.setContext({
    'contributor_fingerprint': 'fp1',
    'connection_id': '11111111-1111-4111-8111-111111111111',
    'writer_epoch': 1,
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

Future<void> closeTestStore(CommunityStore store) async {
  final path = store.path;
  await store.db.close();
  await CommunityStore.closeForTest(path);
  try {
    await Directory(File(path).parent.path).delete(recursive: true);
  } catch (_) {}
}

void main() {
  group('decideEvent', () {
    test('첫 eligible 관측은 completed_observation', () {
      expect(
          decideEvent(
              eligible: true,
              prevSha: null,
              prevEligible: null,
              payloadSha: 'a',
              serverCompletedHit: false),
          equals('completed_observation'));
    });
    test('같은 내용이면 이벤트 없음', () {
      expect(
          decideEvent(
              eligible: true,
              prevSha: 'a',
              prevEligible: true,
              payloadSha: 'a',
              serverCompletedHit: false),
          isNull);
    });
    test('내용이 바뀌면 completed_observation', () {
      expect(
          decideEvent(
              eligible: true,
              prevSha: 'a',
              prevEligible: true,
              payloadSha: 'b',
              serverCompletedHit: false),
          equals('completed_observation'));
    });
    test('적격→부적격은 status_correction', () {
      expect(
          decideEvent(
              eligible: false,
              prevSha: 'a',
              prevEligible: true,
              payloadSha: 'b',
              serverCompletedHit: false),
          equals('status_correction'));
    });
    test('처음부터 부적격이면 이벤트 없음(detail_status 만)', () {
      expect(
          decideEvent(
              eligible: false,
              prevSha: null,
              prevEligible: null,
              payloadSha: 'b',
              serverCompletedHit: false),
          isNull);
    });
    test('server_completed 있으면 첫 비적격도 status_correction', () {
      expect(
          decideEvent(
              eligible: false,
              prevSha: null,
              prevEligible: null,
              payloadSha: 'b',
              serverCompletedHit: true),
          equals('status_correction'));
    });
    test('server_completed 있으면 첫 적격도 completed_observation', () {
      expect(
          decideEvent(
              eligible: true,
              prevSha: null,
              prevEligible: null,
              payloadSha: 'b',
              serverCompletedHit: true),
          equals('completed_observation'));
    });
  });

  group('capture transaction', () {
    late CommunityStore store;
    setUp(() async => store = await openTestStore());
    tearDown(() async => closeTestStore(store));

    test('첫 capture: journal+outbox+report_latest+revision', () async {
      final r = await capture(adapter(), sourceReportId: 'R1',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      expect(r.eventType, equals('completed_observation'));
      expect(r.eventId, isNotNull);
      expect(r.sourceRevision, equals(1));
      final journals = await store.db
          .rawQuery('SELECT * FROM source_journal WHERE event_id=?', [r.eventId]);
      expect(journals.length, equals(1));
      expect(journals.first['personal_save_state'], equals('pending'));
      expect(journals.first['parser_version'], equals('mobile-parser-1'));
      final outbox = await store.db.rawQuery(
          'SELECT * FROM outbox WHERE event_id=?', [r.eventId]);
      expect(outbox.length, equals(1));
      final latest = await store.db.rawQuery(
          'SELECT * FROM report_latest WHERE source_report_id=?', ['R1']);
      expect(latest.length, equals(1));
      final detail = await store.db.rawQuery(
          'SELECT * FROM detail_status WHERE source_report_id=?', ['R1']);
      expect(detail.first['c_now_label'], equals('수용'));
      expect(await store.meta('next_revision'), equals('2'));
    });

    test('이중 capture 없음: 같은 내용 두 번째는 이벤트 없음', () async {
      final r1 = await capture(adapter(), sourceReportId: 'R1',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      final r2 = await capture(adapter(), sourceReportId: 'R1',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      expect(r1.eventId, isNotNull);
      expect(r2.eventId, isNull);
      expect(r2.eventType, isNull);
      final count = await store.db
          .rawQuery('SELECT COUNT(*) AS c FROM source_journal');
      expect(count.first['c'], equals(1));
    });

    test('상태 변경: 적격→취하는 status_correction', () async {
      await capture(adapter(), sourceReportId: 'R1',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      final r = await capture(
          adapter(status: '취하', fine: '', progress: '취하'),
          sourceReportId: 'R1', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      expect(r.eventType, equals('status_correction'));
      expect(r.eligible, isFalse);
      final detail = await store.db.rawQuery(
          'SELECT * FROM detail_status WHERE source_report_id=?', ['R1']);
      expect(detail.first['c_now_label'], equals('취하'));
    });

    test('무이벤트·무prev: report_latest 안 씀, detail_status 만', () async {
      final r = await capture(
          adapter(status: '처리중', fine: '', progress: '처리중'),
          sourceReportId: 'R9', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      expect(r.eventId, isNull);
      final latest = await store.db.rawQuery(
          'SELECT * FROM report_latest WHERE source_report_id=?', ['R9']);
      expect(latest, isEmpty);
      final detail = await store.db.rawQuery(
          'SELECT * FROM detail_status WHERE source_report_id=?', ['R9']);
      expect(detail.length, equals(1));
    });

    test('context inactive 면 outbox 없이 journal 만', () async {
      await store.deactivateContext('test');
      final r = await capture(adapter(), sourceReportId: 'R2',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      expect(r.eventId, isNotNull);
      final outbox = await store.db
          .rawQuery('SELECT * FROM outbox WHERE event_id=?', [r.eventId]);
      expect(outbox, isEmpty);
    });

    test('rebuild: staging 에 쓰고 report_latest 는 그대로', () async {
      final r = await capture(adapter(), sourceReportId: 'R3',
          trigger: 'rebuild', rebuildRunId: 'run1',
          store: store, projectNamespace: 'ns1');
      expect(r.eventType, equals('completed_observation'));
      final staging = await store.db.rawQuery(
          'SELECT * FROM report_latest_staging WHERE run_id=?', ['run1']);
      expect(staging.length, equals(1));
      final latest = await store.db.rawQuery(
          'SELECT * FROM report_latest WHERE source_report_id=?', ['R3']);
      expect(latest, isEmpty);
      // 무변경 재관측 → 기존 포인터 carry-forward.
      final r2 = await capture(adapter(), sourceReportId: 'R3',
          trigger: 'rebuild', rebuildRunId: 'run1',
          store: store, projectNamespace: 'ns1');
      expect(r2.eventId, isNull);
      final staging2 = await store.db.rawQuery(
          'SELECT * FROM report_latest_staging WHERE run_id=?', ['run1']);
      expect(staging2.length, equals(1));
      expect(staging2.first['event_id'], equals(r.eventId));
    });

    test('revision 은 파일 전체 단조 (회전 뒤에도 초기화 안 됨)', () async {
      await capture(adapter(), sourceReportId: 'R1',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      await store.rotateDataset('test');
      final r = await capture(adapter(), sourceReportId: 'R2',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      expect(r.sourceRevision, equals(2));
    });

    test('markPersonalSave + reconcilePendingSaves', () async {
      final r = await capture(adapter(), sourceReportId: 'R1',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      await markPersonalSave(r.eventId, true, store: store);
      final row = await store.db.rawQuery(
          'SELECT personal_save_state AS s FROM source_journal WHERE event_id=?',
          [r.eventId]);
      expect(row.first['s'], equals('saved'));
      // 10분 지난 pending 행: 개인 DB 원본과 status_raw 가 같으면 saved.
      final old = isoUtcForTest(
          DateTime.now().toUtc().subtract(const Duration(minutes: 11)));
      await store.db.rawUpdate(
          "UPDATE source_journal SET personal_save_state='pending', captured_at=? WHERE event_id=?",
          [old, r.eventId]);
      final fixed = await reconcilePendingSaves((id) async => '수용',
          store: store);
      expect(fixed, equals(1));
      final row2 = await store.db.rawQuery(
          'SELECT personal_save_state AS s FROM source_journal WHERE event_id=?',
          [r.eventId]);
      expect(row2.first['s'], equals('saved'));
    });

    test('CaptureTracker 3회 연속 실패면 중단 신호', () {
      final t = CaptureTracker();
      expect(t.recordFailure(), isFalse);
      expect(t.recordFailure(), isFalse);
      expect(t.recordFailure(), isTrue);
      t.recordSuccess();
      expect(t.recordFailure(), isFalse);
    });

    test('retry 파일 add/remove/ids (원자 쓰기)', () async {
      final dir = await Directory.systemTemp.createTemp('sr_t6_retry_');
      final file = File('${dir.path}/community_capture_retry.json');
      await CaptureRetryStore.addIntent(file, 'R1', 'capture_pending');
      await CaptureRetryStore.addIntent(file, 'R2', 'capture_pending');
      expect(await CaptureRetryStore.captureRetryIds(file),
          equals({'R1', 'R2'}));
      await CaptureRetryStore.removeIntent(file, 'R1');
      expect(await CaptureRetryStore.captureRetryIds(file), equals({'R2'}));
      await dir.delete(recursive: true);
    });

    test('refreshServerCompleted: 교체·scope 기록·토큰 불일치 재시도', () async {
      var calls = 0;
      Future<ManifestPage?> ok(String? after, int limit) async {
        calls++;
        if (after == null) {
          return const ManifestPage(
              keys: ['aaaaaaaaaaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbbbbbbbbbb'],
              manifestToken: '7',
              after: 'bbbbbbbbbbbbbbbbbbbbbbbb');
        }
        return const ManifestPage(keys: ['cccccccccccccccccccccccc'], manifestToken: '7');
      }

      final okResult = await refreshServerCompleted(
          datasetKey: 'ds1', writerEpoch: 1, fetchPage: ok, store: store);
      expect(okResult, isTrue);
      expect(calls, equals(2));
      final rows = await store.db
          .rawQuery('SELECT * FROM server_completed WHERE dataset_key=?', ['ds1']);
      expect(rows.length, equals(3));
      expect(await store.meta('manifest_scope'), equals('ds1:1'));

      Future<ManifestPage?> flapping(String? after, int limit) async {
        if (after == null) {
          return ManifestPage(
              keys: const ['dddddddddddddddddddddddd'],
              manifestToken: '8',
              after: 'cursor1');
        }
        return const ManifestPage(
            keys: ['eeeeeeeeeeeeeeeeeeeeeeee'], manifestToken: '9');
      }
      final fail = await refreshServerCompleted(
          datasetKey: 'ds1', writerEpoch: 2, fetchPage: flapping, store: store);
      expect(fail, isFalse);
      // 실패해도 기존 manifest 는 그대로.
      final rows2 = await store.db
          .rawQuery('SELECT * FROM server_completed WHERE dataset_key=?', ['ds1']);
      expect(rows2.length, equals(3));
    });

    test('onContributionsDeleted: 대기 blocked·이전 journal 표시·manifest 비움',
        () async {
      await capture(adapter(), sourceReportId: 'R1',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      await store.db.insert('server_completed', {
        'dataset_key': 'ds1',
        'key_prefix': 'a' * 24,
        'fetched_at': isoUtcForTest(DateTime.now().toUtc()),
      });
      await onContributionsDeleted(
          deletedAt: DateTime.now().toUtc().add(const Duration(seconds: 1)),
          store: store);
      final outbox =
          await store.db.rawQuery('SELECT state FROM outbox');
      expect(outbox.first['state'], equals('blocked'));
      final journal = await store.db
          .rawQuery('SELECT blocked_reason AS b FROM source_journal');
      expect(journal.first['b'], equals('deleted_by_user'));
      final manifest =
          await store.db.rawQuery('SELECT * FROM server_completed');
      expect(manifest, isEmpty);
      // 삭제 뒤 reshare 후보 0.
      expect(await reshareCandidates(store: store), equals(0));
    });

    test('issueReshare: payload·captured_at 유지, 새 revision', () async {
      final r = await capture(adapter(), sourceReportId: 'R1',
          trigger: 'realtime', store: store, projectNamespace: 'ns1');
      final id =
          await issueReshare('R1', store: store);
      expect(id, isNotNull);
      final rows = await store.db.rawQuery(
          'SELECT * FROM source_journal WHERE event_id=?', [id]);
      final orig = await store.db.rawQuery(
          'SELECT * FROM source_journal WHERE event_id=?', [r.eventId]);
      expect(rows.first['event_type'], equals('reshare'));
      expect(rows.first['payload_json'], equals(orig.first['payload_json']));
      expect(rows.first['captured_at'], equals(orig.first['captured_at']));
      expect(rows.first['source_revision'],
          equals((r.sourceRevision ?? 0) + 1));
      expect(await reshareCandidates(store: store), equals(1));
    });

    test('server_completed hit: 첫 비적격도 status_correction', () async {
      final prefix = sourceReportKeyPrefix('RX');
      await store.db.insert('server_completed', {
        'dataset_key': 'ds1',
        'key_prefix': prefix,
        'fetched_at': isoUtcForTest(DateTime.now().toUtc()),
      });
      final r = await capture(
          adapter(status: '처리중', fine: '', progress: '처리중'),
          sourceReportId: 'RX', trigger: 'realtime',
          store: store, projectNamespace: 'ns1');
      expect(r.eventType, equals('status_correction'));
    });
  });
}

String isoUtcForTest(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${three(u.millisecond)}Z';
}
