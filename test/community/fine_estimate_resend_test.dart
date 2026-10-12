// 기존 신고 다시 보내기(크롤링 없음) — fine-estimate-contract.md "기존 신고 다시 보내기".
//
// 크롤링·공식 사이트 접근 없이, 이미 커뮤니티에 올라간 적 있는 신고(report_latest)를 로컬
// personal DB 값으로 다시 capture() 한다. payload_sha256 이 바뀐 것(=fine_estimate 가 새로
// 생긴 것)만 새 journal/outbox 를 만든다.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/fine_estimate_resend.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/fine_estimate.dart' as fine_estimate;
import 'package:safetyreport/services/local_db_service.dart';

Report _report({
  required String id,
  required String fineInfo,
  String carNumber = '12가3456',
}) => Report(
  id: id,
  reportNumber: 'SPP-2609-$id',
  name: '장애인구역 불법주차',
  date: '2026-09-01',
  responseDate: '2026-09-10',
  agency: '서울특별시 중구청',
  manager: '홍길동',
  status: '수용',
  result: '수용',
  fineInfo: fineInfo,
  penaltyPoints: '',
  carNumber: carNumber,
  law: '',
  location: '서울특별시 중구 세종대로 110',
  occurrenceDate: '2026-09-01',
  occurrenceTime: '10:00',
  reportContent: '',
  processContent: '',
);

const _entryValue = '불법주정차신고-장애인 전용구역 불법주차';

/// capture() 가 저장했을 payload_json·sha 를 production 코드로 계산한다(테스트에서 다시
/// 구현하지 않음). [withFineEstimate]=false 면 fine_estimate 키를 지운 "업데이트 전" payload다.
Future<({String json, String sha})> _payloadFor(
  String id, {
  bool withFineEstimate = true,
}) async {
  final rows = await LocalDbService.communityResendRows([id]);
  final payload = Map<String, Object?>.from(
    buildPayload(adapterInputFromResendRow(rows.single)),
  );
  if (!withFineEstimate) payload.remove('fine_estimate');
  final json = canonicalJson(payload);
  return (json: json, sha: sha256.convert(utf8.encode(json)).toString());
}

/// 업데이트 전(fine_estimate 없는) journal+report_latest 행을 심는다 — 이미 전송·ACK 돼
/// outbox 는 비어 있는 상태(기존 수명주기, local-store.md "outbox 는 durable ACK 때 삭제").
/// [revision] 은 서로 달라야 한다(source_journal UNIQUE (local_dataset_id, source_revision)) —
/// meta.next_revision 도 그보다 높여 둬야 실제 capture() 재발급이 같은 번호와 부딪히지 않는다.
Future<void> _seedOldJournal(
  CommunityStore store,
  String id, {
  required int revision,
}) async {
  final old = await _payloadFor(id, withFineEstimate: false);
  final eventId = 'old-$id';
  await store.db.insert('source_journal', {
    'event_id': eventId,
    'project_namespace': 'ns1',
    'local_dataset_id': await store.localDatasetId(),
    'dataset_key': 'ds1',
    'source_report_id': id,
    'report_number': 'SPP-2609-$id',
    'source_revision': revision,
    'event_type': 'completed_observation',
    'captured_at': '2026-10-01T00:00:00.000Z',
    'capture_trigger': 'realtime',
    'schema_version': 1,
    'parser_version': 'mobile-parser-5',
    'payload_json': old.json,
    'payload_sha256': old.sha,
    'eligible': 1,
    'contributor_fingerprint': 'fp1',
    'connection_id': '11111111-1111-4111-8111-111111111111',
    'writer_epoch': 1,
    'consent_grant_id': '22222222-2222-4222-8222-222222222222',
    'personal_save_state': 'saved',
  });
  await store.db.insert('report_latest', {
    'local_dataset_id': await store.localDatasetId(),
    'source_report_id': id,
    'event_id': eventId,
    'payload_sha256': old.sha,
    'eligible': 1,
    'source_generation': 0,
  });
  // 실제 capture() 의 nextRevision() 이 이미 쓴 번호와 겹치지 않게.
  await store.setMeta('next_revision', '${revision + 1}');
}

Future<CommunityStore> _openStore({bool activeContext = true}) async {
  final dir = await Directory.systemTemp.createTemp('sr_fine_estimate_resend_');
  final store = await CommunityStore.open(
    path: '${dir.path}/community.db',
    factory: databaseFactoryFfi,
  );
  if (activeContext) {
    await store.setContext({
      'contributor_fingerprint': 'fp1',
      'connection_id': '11111111-1111-4111-8111-111111111111',
      'writer_epoch': 1,
      'dataset_key': 'ds1',
      'consent_grant_id': '22222222-2222-4222-8222-222222222222',
      'policy_version': '2026-09-28.1',
      'consent_text_sha256': 'abc',
      'source_app': 'safetyreport-mobile',
      'source_mode': 'standalone',
    });
  }
  await store.setMeta('project_namespace', 'ns1');
  return store;
}

Future<void> _closeStore(CommunityStore store) async {
  final path = store.path;
  await store.db.close();
  await CommunityStore.closeForTest(path);
  try {
    await Directory(File(path).parent.path).delete(recursive: true);
  } catch (_) {}
}

void main() {
  late Directory tempDbDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(
      (tempDbDir = Directory.systemTemp.createTempSync('sr_fer_personal_')).path,
    );
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
  });

  tearDown(() async {
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
  });

  Future<void> seedReports() async {
    // R1: 과태료 미확인 — fine_estimate 대상(disabled_parking).
    await LocalDbService.upsertReport(
      _report(id: 'R1', fineInfo: '과태료'),
      'parking',
      _entryValue,
    );
    // R2: 과태료 확정 — fine_estimate 대상 아님(계속 대상 아님).
    await LocalDbService.upsertReport(
      _report(id: 'R2', fineInfo: '과태료: 100,000원'),
      'parking',
      _entryValue,
    );
  }

  test('파서 7은 오타 보정 신고를 크롤링 없이 한 번 다시 보낸다', () async {
    final store = await _openStore();
    try {
      await LocalDbService.upsertReport(_report(id: 'T1', fineInfo: '과태료: 40,0000원'), 'parking', '불법주정차신고');
      await _seedOldJournal(store, 'T1', revision: 1);
      final rows = await LocalDbService.communityResendRows(['T1']);
      final old = Map<String, Object?>.from(buildPayload(adapterInputFromResendRow(rows.single)));
      (old['amount'] as Map)['confirmed_won'] = null;
      old['fine_estimate'] = {'won': 40000, 'rule': 'parking', 'rule_version': fine_estimate.ruleVersion};
      final oldJson = canonicalJson(old);
      final oldSha = sha256.convert(utf8.encode(oldJson)).toString();
      await store.db.update('source_journal', {'payload_json': oldJson, 'payload_sha256': oldSha, 'parser_version': 'mobile-parser-6'}, where: 'source_report_id=?', whereArgs: ['T1']);
      await store.db.update('report_latest', {'payload_sha256': oldSha}, where: 'source_report_id=?', whereArgs: ['T1']);
      await store.setMeta('fine_estimate_resend_done', '${fine_estimate.ruleVersion}|mobile-parser-6');
      expect(await resendFineEstimateIfNeeded(store: store), 1);
      final events = await store.db.rawQuery("SELECT * FROM source_journal WHERE source_report_id='T1' ORDER BY source_revision");
      expect(events.length, 2);
      expect(events.last['parser_version'], 'mobile-parser-7');
      expect((jsonDecode(events.last['payload_json'] as String)['amount'] as Map)['confirmed_won'], 40000);
      expect(await resendFineEstimateIfNeeded(store: store), 0);
      final stored = await LocalDbService.communityResendRows(['T1']);
      expect(stored.single['범칙금_과태료'], '과태료: 40,0000원');
    } finally {
      await _closeStore(store);
    }
  });

  test('필드 생김: 대상 신고만 새 journal+outbox, 대상 아닌 신고는 그대로', () async {
    final store = await _openStore();
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);
      await _seedOldJournal(store, 'R2', revision: 2);

      final resent = await resendFineEstimateIfNeeded(store: store);
      expect(resent, equals(1));

      final r1 = await store.db.rawQuery(
        "SELECT * FROM source_journal WHERE source_report_id='R1' ORDER BY source_revision",
      );
      expect(r1.length, equals(2), reason: 'R1 은 새 이벤트가 생겨야 한다');
      expect(r1.last['capture_trigger'], equals('fine_estimate_resend'));
      final newPayload = jsonDecode(r1.last['payload_json'] as String) as Map;
      expect(newPayload['fine_estimate'], equals({
        'won': 100000,
        'rule': 'disabled_parking',
        'rule_version': fine_estimate.ruleVersion,
      }));
      final r1Outbox = await store.db.rawQuery(
        "SELECT * FROM outbox WHERE event_id=?",
        [r1.last['event_id']],
      );
      expect(r1Outbox.length, equals(1), reason: '동의·계정 문맥이 있으면 보낸다');

      final r2 = await store.db.rawQuery(
        "SELECT * FROM source_journal WHERE source_report_id='R2'",
      );
      expect(r2.length, equals(1), reason: 'R2 는 대상이 아니라 payload 가 안 바뀐다');
    } finally {
      await _closeStore(store);
    }
  });

  test('1회성: 완료 뒤 다시 돌리면 아무 일도 하지 않는다', () async {
    final store = await _openStore();
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);

      final first = await resendFineEstimateIfNeeded(store: store);
      expect(first, equals(1));
      final afterFirst = await store.db.rawQuery(
        "SELECT COUNT(*) AS n FROM source_journal WHERE source_report_id='R1'",
      );

      final second = await resendFineEstimateIfNeeded(store: store);
      expect(second, equals(0));
      final afterSecond = await store.db.rawQuery(
        "SELECT COUNT(*) AS n FROM source_journal WHERE source_report_id='R1'",
      );
      expect(afterSecond.first['n'], equals(afterFirst.first['n']));
    } finally {
      await _closeStore(store);
    }
  });

  test('재개: 이전 실행이 R1 까지 끝내고 멈췄으면 R1 은 다시 보지 않고 R2 부터', () async {
    final store = await _openStore();
    try {
      // R1·R2 둘 다 fine_estimate 대상(disabled_parking, 과태료 미확인).
      for (final id in ['R1', 'R2']) {
        await LocalDbService.upsertReport(
          _report(id: id, fineInfo: '과태료'),
          'parking',
          _entryValue,
        );
      }
      await _seedOldJournal(store, 'R1', revision: 1);
      await _seedOldJournal(store, 'R2', revision: 2);

      // 이전 실행이 R1 까지 처리하고 멈춘 상태를 흉내낸다: 커서를 R1 로, 버전은 지금 버전으로.
      final target = '${fine_estimate.ruleVersion}|$mobileParserVersion';
      await store.setMeta('fine_estimate_resend_cursor', 'R1');
      await store.setMeta('fine_estimate_resend_cursor_version', target);

      final resent = await resendFineEstimateIfNeeded(store: store);
      expect(resent, equals(1), reason: 'R1 은 건너뛰고 R2 만 다시 보낸다');
      final r1 = await store.db.rawQuery(
        "SELECT COUNT(*) AS n FROM source_journal WHERE source_report_id='R1'",
      );
      expect(r1.first['n'], equals(1), reason: 'R1 은 커서 이전이라 다시 보지 않는다');
      final r2 = await store.db.rawQuery(
        "SELECT COUNT(*) AS n FROM source_journal WHERE source_report_id='R2'",
      );
      expect(r2.first['n'], equals(2));
    } finally {
      await _closeStore(store);
    }
  });

  test('동의·계정 문맥 없음: journal 은 쌓여도 outbox 로 보내지 않는다', () async {
    final store = await _openStore(activeContext: false);
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);

      final resent = await resendFineEstimateIfNeeded(store: store);
      expect(resent, equals(1));
      final journal = await store.db.rawQuery(
        "SELECT * FROM source_journal WHERE source_report_id='R1' ORDER BY source_revision DESC LIMIT 1",
      );
      expect(journal.single['blocked_reason'], equals('no_active_context'));
      final outbox = await store.db.rawQuery(
        "SELECT * FROM outbox WHERE event_id=?",
        [journal.single['event_id']],
      );
      expect(outbox, isEmpty);
    } finally {
      await _closeStore(store);
    }
  });
}
