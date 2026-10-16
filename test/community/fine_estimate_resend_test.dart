// 기존 신고 다시 보내기(크롤링 없음) — fine-estimate-contract.md "기존 신고 다시 보내기".
//
// 크롤링·공식 사이트 접근 없이, 이미 커뮤니티에 올라간 적 있는 신고(report_latest)를 로컬
// personal DB의 추정 입력으로 journal 최신 payload의 fine_estimate만 갱신한다.
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

// 실시간 수집/예전 journal fixture용 전체 원문 입력. 재전송 어댑터와 분리한다.
Future<Map<String, Object?>> _observationInput(String id) async {
  final db = await LocalDbService.db;
  final row = (await db.query(
    'reports',
    where: 'ID=?',
    whereArgs: [id],
  )).single;
  String value(String key) => row[key]?.toString() ?? '';
  return buildAdapterInput(
    status: value('처리상태'),
    reportNumber: value('신고번호'),
    fineInfo: value('범칙금_과태료'),
    date: value('신고일'),
    responseDate: value('답변일'),
    agency: value('처리기관'),
    agencyCode: row['처리기관코드'] as String?,
    manager: value('담당자'),
    carNumber: value('차량번호'),
    location: value('위반장소'),
    penaltyPoints: value('벌점'),
    entryValue: value('entry_value'),
    ssnpcCd: row['ssnpc_cd'] as String?,
    ssnpcType: row['ssnpc_type'] as String?,
    violationLaw: value('위반법규'),
    progressStatus: value('상태'),
    reportName: value('신고명'),
    occurrenceTime: value('발생시각'),
    photoFirstCapture: row['사진_첫촬영'] as String?,
    photoLastCapture: row['사진_끝촬영'] as String?,
  );
}

/// capture() 가 저장했을 payload_json·sha 를 production 코드로 계산한다(테스트에서 다시
/// 구현하지 않음). [withFineEstimate]=false 면 fine_estimate 키를 지운 "업데이트 전" payload다.
Future<({String json, String sha})> _payloadFor(
  String id, {
  bool withFineEstimate = true,
}) async {
  final payload = buildPayload(await _observationInput(id));
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
      (tempDbDir = Directory.systemTemp.createTempSync(
        'sr_fer_personal_',
      )).path,
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

  for (final saveState in ['failed', 'pending']) {
    test('$saveState 개인 저장 뒤 재전송은 최신 확정 답변을 되돌리지 않는다', () async {
      final store = await _openStore();
      try {
        await seedReports();
        await _seedOldJournal(store, 'R1', revision: 1);
        final input = await _observationInput('R1');
        final latest = await capture(
          {
            ...input,
            'penalty_amount': '과태료: 200,000원',
            'response_date': '2026-10-13',
            'processing_agency': '최신 기관',
            'report_number': 'SPP-NEW-R1',
            'progress_status': '처리완료',
          },
          sourceReportId: 'R1',
          trigger: 'realtime',
          store: store,
        );
        if (saveState == 'failed') {
          await markPersonalSave(latest.eventId, false, store: store);
        }
        final before = await store.db.query(
          'source_journal',
          orderBy: 'source_revision',
        );
        final detail = await store.db.query('detail_status');
        final outbox = await store.db.query('outbox');
        expect(await resendFineEstimateIfNeeded(store: store), 0);
        expect(
          await store.db.query('source_journal', orderBy: 'source_revision'),
          before,
        );
        expect(await store.db.query('detail_status'), detail);
        expect(await store.db.query('outbox'), outbox);
      } finally {
        await _closeStore(store);
      }
    });

    test('$saveState 개인 저장 상태로 추정 갱신을 막지 않고 나머지 최신 필드를 보존한다', () async {
      final store = await _openStore();
      try {
        await seedReports();
        await _seedOldJournal(store, 'R1', revision: 1);
        final old = (await store.db.query('source_journal')).single;
        final payload =
            jsonDecode(old['payload_json'] as String) as Map<String, dynamic>;
        payload.addAll({
          'agency_name': '최신 기관',
          'completed_date': '2026-10-13',
          'vehicle_raw': '99나9999',
          'violation_law': '최신 법규',
          'rating': 5,
          'source_agency_code': '000123',
          'location': {'lat': '37.1', 'lng': '127.1', 'source': 'geocode'},
        });
        final canonical = canonicalJson(payload);
        final sha = sha256.convert(utf8.encode(canonical)).toString();
        await store.db.update('source_journal', {
          'payload_json': canonical,
          'payload_sha256': sha,
          'personal_save_state': saveState,
          'report_number': 'SPP-NEW-R1',
        });
        await store.db.update('report_latest', {'payload_sha256': sha});
        expect(await resendFineEstimateIfNeeded(store: store), 1);
        final events = await store.db.query(
          'source_journal',
          orderBy: 'source_revision',
        );
        final updated =
            jsonDecode(events.last['payload_json'] as String)
                as Map<String, dynamic>;
        expect(updated.remove('fine_estimate'), {
          'won': 100000,
          'rule': 'disabled_parking',
          'rule_version': fine_estimate.ruleVersion,
        });
        expect(updated, payload);
        expect(events.last['report_number'], 'SPP-NEW-R1');
        expect(events.first['personal_save_state'], saveState);
        expect((await store.db.query('outbox')).length, 1);
      } finally {
        await _closeStore(store);
      }
    });
  }

  test('개인 DB 원문이 journal 금액 판정과 다르면 추정을 싣지 않는다(PC와 같음)', () async {
    final store = await _openStore();
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);
      // 개인 DB는 아직 과태료 처분조차 저장되지 않은 옛 상태다(개인 저장 지연).
      await LocalDbService.upsertReport(
        _report(id: 'R1', fineInfo: '계도'),
        'parking',
        _entryValue,
      );
      final before = await store.db.query('source_journal');
      expect(await resendFineEstimateIfNeeded(store: store), 0);
      expect(await store.db.query('source_journal'), before);
      expect(await store.db.query('outbox'), isEmpty);
    } finally {
      await _closeStore(store);
    }
  });

  test('재공유 이력은 계정별 과거 payload가 아닌 신고의 최신 journal을 기준으로 한다', () async {
    final store = await _openStore();
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);
      final original = (await store.db.query('source_journal')).single;
      final latestPayload =
          jsonDecode(original['payload_json'] as String)
              as Map<String, dynamic>;
      latestPayload['agency_name'] = '재공유 최신 기관';
      latestPayload['fine_estimate'] = {
        'won': 100000,
        'rule': 'disabled_parking',
        'rule_version': fine_estimate.ruleVersion,
      };
      final canonical = canonicalJson(latestPayload);
      final sha = sha256.convert(utf8.encode(canonical)).toString();
      await store.db.insert('source_journal', {
        ...original,
        'event_id': 'reshared-R1',
        'source_revision': 2,
        'dataset_key': 'ds2',
        'contributor_fingerprint': 'fp2',
        'payload_json': canonical,
        'payload_sha256': sha,
      });
      await store.setMeta('next_revision', '3');
      // report_latest/현 계정 이력은 예전 관측을 가리켜도 최신 revision을 읽는다.
      expect(await resendFineEstimateIfNeeded(store: store), 0);
      expect((await store.db.query('source_journal')).length, 2);
      expect(await store.db.query('outbox'), isEmpty);
      await LocalDbService.upsertReport(
        _report(id: 'R1', fineInfo: '과태료'),
        'parking',
        '불법주정차신고',
      );
      await store.setMeta('fine_estimate_resend_done', 'old');
      await store.setMeta('fine_estimate_resend_cursor_version', 'old');
      expect(await resendFineEstimateIfNeeded(store: store), 1);
      final events = await store.db.query(
        'source_journal',
        orderBy: 'source_revision',
      );
      final updated =
          jsonDecode(events.last['payload_json'] as String)
              as Map<String, dynamic>;
      expect((updated.remove('fine_estimate') as Map)['won'], 40000);
      latestPayload.remove('fine_estimate');
      expect(updated, latestPayload);
      expect(events.last['dataset_key'], 'ds1');
    } finally {
      await _closeStore(store);
    }
  });

  for (final scenario in ['confirmed', 'zero', 'penalty', 'no_rule']) {
    test('$scenario 최신 관측의 낡은 추정 필드만 제거한다', () async {
      final store = await _openStore();
      try {
        await seedReports();
        await _seedOldJournal(store, 'R1', revision: 1);
        final payload =
            jsonDecode(
                  (await store.db.query(
                        'source_journal',
                      )).single['payload_json']
                      as String,
                )
                as Map<String, dynamic>;
        payload['fine_estimate'] = {
          'won': 100000,
          'rule': 'disabled_parking',
          'rule_version': 'old',
        };
        if (scenario == 'confirmed' || scenario == 'zero') {
          (payload['amount'] as Map)['confirmed_won'] = scenario == 'zero'
              ? 0
              : 200000;
        } else if (scenario == 'penalty') {
          (payload['amount'] as Map)['kind'] = 'penalty';
        } else {
          final db = await LocalDbService.db;
          await db.update(
            'reports',
            {'entry_value': '안전신고', 'ssnpc_cd': 'CM', 'ssnpc_type': '07'},
            where: 'ID=?',
            whereArgs: ['R1'],
          );
        }
        final canonical = canonicalJson(payload);
        final sha = sha256.convert(utf8.encode(canonical)).toString();
        await store.db.update('source_journal', {
          'payload_json': canonical,
          'payload_sha256': sha,
        });
        await store.db.update('report_latest', {'payload_sha256': sha});
        expect(await resendFineEstimateIfNeeded(store: store), 1);
        final events = await store.db.query(
          'source_journal',
          orderBy: 'source_revision',
        );
        payload.remove('fine_estimate');
        expect(jsonDecode(events.last['payload_json'] as String), payload);
        expect(await resendFineEstimateIfNeeded(store: store), 0);
      } finally {
        await _closeStore(store);
      }
    });
  }

  test('발급 트랜잭션에서 최신 journal을 읽고 개인 DB 법규로 추정한다', () async {
    final store = await _openStore();
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);
      final db = await LocalDbService.db;
      await db.update(
        'reports',
        {
          'entry_value': '자동차·교통위반',
          'ssnpc_cd': 'TV',
          'ssnpc_type': '02',
          '신고명': '교통위반',
          '위반법규': '도로교통법 제15조\n도로교통법 제5조',
        },
        where: 'ID=?',
        whereArgs: ['R1'],
      );
      final row = (await LocalDbService.communityResendRows(['R1'])).single;
      expect(
        row.keys,
        unorderedEquals([
          'ID',
          '신고명',
          '차량번호',
          '발생시각',
          'entry_value',
          'ssnpc_cd',
          'ssnpc_type',
          '사진_첫촬영',
          '사진_끝촬영',
          '범칙금_과태료',
          '위반법규',
        ]),
      );
      expect(adapterInputFromResendRow(row)['violation_law'], '도로교통법 제15조');
      final original = (await store.db.query('source_journal')).single;
      final latestPayload =
          jsonDecode(original['payload_json'] as String)
              as Map<String, dynamic>;
      // journal 법규가 아니라 개인 DB 현재 법규로 판정한다(일반 캡처와 같은 입력).
      latestPayload['violation_law'] = '오래된 법규';
      latestPayload['agency_name'] = '트랜잭션 직전 관측';
      final canonical = canonicalJson(latestPayload);
      final result = await capture(
        adapterInputFromResendRow(row),
        sourceReportId: 'R1',
        trigger: 'fine_estimate_resend',
        store: store,
        beforeWrite: (tx) async {
          await tx.insert('source_journal', {
            ...original,
            'event_id': 'new-at-write',
            'source_revision': 2,
            'payload_json': canonical,
            'payload_sha256': sha256.convert(utf8.encode(canonical)).toString(),
          });
          await store.setMeta('next_revision', '3', tx);
        },
      );
      expect(result.eventId, isNotNull);
      final events = await store.db.query(
        'source_journal',
        orderBy: 'source_revision',
      );
      final updated = jsonDecode(events.last['payload_json'] as String) as Map;
      expect(updated.remove('fine_estimate'), {
        'won': 50000,
        'rule': 'bus_lane',
        'rule_version': fine_estimate.ruleVersion,
      });
      expect(updated, latestPayload);
      expect(await store.db.query('detail_status'), isEmpty);
    } finally {
      await _closeStore(store);
    }
  });

  test('삭제 차단된 미전송 자료는 새 연결에서도 재발급하지 않는다', () async {
    final store = await _openStore();
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);
      await store.db.update('source_journal', {
        'blocked_reason': 'deleted_by_user',
      });
      expect(await resendFineEstimateIfNeeded(store: store), 0);
      expect((await store.db.query('source_journal')).length, 1);
      expect(await store.db.query('outbox'), isEmpty);
    } finally {
      await _closeStore(store);
    }
  });

  test('후보 조회 뒤 삭제되어도 발급 트랜잭션에서 차단을 재확인한다', () async {
    final store = await _openStore();
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);
      final input = adapterInputFromResendRow(
        (await LocalDbService.communityResendRows(['R1'])).single,
      );
      final result = await capture(
        input,
        sourceReportId: 'R1',
        trigger: 'fine_estimate_resend',
        store: store,
        beforeWrite: (tx) async {
          await tx.update('source_journal', {
            'blocked_reason': 'deleted_by_user',
          });
        },
      );
      expect(result.eventId, isNull);
      expect((await store.db.query('source_journal')).length, 1);
      expect(await store.db.query('outbox'), isEmpty);
    } finally {
      await _closeStore(store);
    }
  });

  test('personal_sync 소유자가 있으면 재전송하지 않고 다음 실행에 최신 답변을 읽는다', () async {
    final store = await _openStore();
    try {
      await seedReports();
      await _seedOldJournal(store, 'R1', revision: 1);
      await store.acquireLease(
        'personal_sync',
        'sync-owner',
        const Duration(minutes: 10),
      );
      expect(await resendFineEstimateIfNeeded(store: store), 0);
      expect(await store.meta('fine_estimate_resend_done'), isNull);
      await capture(
        {...await _observationInput('R1'), 'penalty_amount': '과태료: 200,000원'},
        sourceReportId: 'R1',
        trigger: 'realtime',
        store: store,
      );
      await LocalDbService.upsertReport(
        _report(id: 'R1', fineInfo: '과태료: 200,000원'),
        'parking',
        _entryValue,
      );
      await store.releaseLease('personal_sync', 'sync-owner');
      expect(await resendFineEstimateIfNeeded(store: store), 0);
      final events = await store.db.query(
        'source_journal',
        orderBy: 'source_revision',
      );
      expect(
        jsonDecode(
          events.last['payload_json'] as String,
        )['amount']['confirmed_won'],
        200000,
      );
    } finally {
      await _closeStore(store);
    }
  });

  test('이륜 규칙 버전 변경은 오계산 교정만 한 번 재전송한다', () async {
    final store = await _openStore();
    try {
      final oldPayloads = <String, Map>{};
      for (final id in ['M1', 'M2']) {
        await LocalDbService.upsertReport(
          _report(id: id, fineInfo: '과태료', carNumber: '경기군포다2671'),
          id == 'M1' ? 'parking' : 'traffic',
          id == 'M1' ? '불법주정차신고' : '교통위반-버스전용차로 위반',
        );
        final db = await LocalDbService.db;
        await db.update('reports', {
          '신고명': id == 'M1' ? '불법주정차 위반' : '버스전용차로 위반',
          'ssnpc_cd': id == 'M1' ? 'EP' : 'TV',
          'ssnpc_type': null,
        }, where: 'ID=?', whereArgs: [id]);
        await _seedOldJournal(store, id, revision: id == 'M1' ? 1 : 2);
        final old = buildPayload(await _observationInput(id));
        old['fine_estimate'] = {
          'won': id == 'M1' ? 40000 : 50000,
          'rule': id == 'M1' ? 'parking' : 'bus_lane',
          'rule_version': '2026-10-12.1',
        };
        oldPayloads[id] = old;
        final text = canonicalJson(old);
        final sha = sha256.convert(utf8.encode(text)).toString();
        await store.db.update('source_journal', {
          'payload_json': text, 'payload_sha256': sha,
          'parser_version': mobileParserVersion,
        }, where: 'source_report_id=?', whereArgs: [id]);
        await store.db.update('report_latest', {'payload_sha256': sha},
          where: 'source_report_id=?', whereArgs: [id]);
      }
      await store.setMeta('fine_estimate_resend_done', '2026-10-12.1|$mobileParserVersion');
      expect(await resendFineEstimateIfNeeded(store: store), 2);
      for (final id in ['M1', 'M2']) {
        final events = await store.db.query('source_journal',
          where: 'source_report_id=?', whereArgs: [id], orderBy: 'source_revision');
        expect(events.length, 2);
        final updated = jsonDecode(events.last['payload_json'] as String) as Map;
        if (id == 'M1') {
          expect(updated.containsKey('fine_estimate'), isFalse);
        } else {
          expect(updated['fine_estimate'], {
            'won': 40000, 'rule': 'bus_lane', 'rule_version': fine_estimate.ruleVersion,
          });
        }
        updated.remove('fine_estimate');
        oldPayloads[id]!.remove('fine_estimate');
        expect(updated, oldPayloads[id], reason: '추정 외 원문은 보존한다');
      }
      expect(await resendFineEstimateIfNeeded(store: store), 0);
    } finally {
      await _closeStore(store);
    }
  });

  test('금액표 보정으로 확정 금액이 읽히면 amount 는 보존하고 낡은 추정만 걷어 낸다', () async {
    final store = await _openStore();
    try {
      await LocalDbService.upsertReport(
        _report(id: 'T1', fineInfo: '과태료: 40,0000원'),
        'parking',
        '불법주정차신고',
      );
      await _seedOldJournal(store, 'T1', revision: 1);
      final old = buildPayload(await _observationInput('T1'));
      (old['amount'] as Map)['confirmed_won'] = null;
      old['fine_estimate'] = {
        'won': 40000,
        'rule': 'parking',
        'rule_version': 'old-rule',
      };
      final oldJson = canonicalJson(old);
      final oldSha = sha256.convert(utf8.encode(oldJson)).toString();
      await store.db.update(
        'source_journal',
        {
          'payload_json': oldJson,
          'payload_sha256': oldSha,
          'parser_version': 'mobile-parser-6',
        },
        where: 'source_report_id=?',
        whereArgs: ['T1'],
      );
      await store.db.update(
        'report_latest',
        {'payload_sha256': oldSha},
        where: 'source_report_id=?',
        whereArgs: ['T1'],
      );
      await store.setMeta(
        'fine_estimate_resend_done',
        '${fine_estimate.ruleVersion}|mobile-parser-6',
      );
      expect(await resendFineEstimateIfNeeded(store: store), 1);
      final events = await store.db.rawQuery(
        "SELECT * FROM source_journal WHERE source_report_id='T1' ORDER BY source_revision",
      );
      expect(events.length, 2);
      expect(events.last['parser_version'], 'mobile-parser-12');
      final updated = jsonDecode(events.last['payload_json'] as String) as Map;
      expect((updated['amount'] as Map)['confirmed_won'], isNull);
      expect(updated.containsKey('fine_estimate'), isFalse);
      old.remove('fine_estimate');
      expect(updated, old);
      expect(await resendFineEstimateIfNeeded(store: store), 0);
      expect(
        (await _observationInput('T1'))['penalty_amount'],
        '과태료: 40,0000원',
      );
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
      expect(
        newPayload['fine_estimate'],
        equals({
          'won': 100000,
          'rule': 'disabled_parking',
          'rule_version': fine_estimate.ruleVersion,
        }),
      );
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

  test('사진 보충 뒤 refreshFineEstimateFor 는 완료 표시와 무관하게 그 신고의 추정만 갱신한다', () async {
    final store = await _openStore();
    try {
      await LocalDbService.upsertReport(
        _report(id: 'P1', fineInfo: '과태료'),
        'parking',
        '불법주정차신고',
      );
      await _seedOldJournal(store, 'P1', revision: 1);
      expect(await resendFineEstimateIfNeeded(store: store), 1);
      final before = await store.db.query(
        'source_journal',
        orderBy: 'source_revision',
      );
      expect(
        (jsonDecode(before.last['payload_json'] as String)
            as Map)['fine_estimate']['won'],
        40000,
      );
      final db = await LocalDbService.db;
      await db.update(
        'reports',
        {
          '사진_첫촬영': '2026-09-01 10:00:00',
          '사진_끝촬영': '2026-09-01 12:01:00',
          '사진_촬영수': 2,
        },
        where: 'ID=?',
        whereArgs: ['P1'],
      );
      final cap = await refreshFineEstimateFor('P1', store: store);
      expect(cap?.eventId, isNotNull);
      final events = await store.db.query(
        'source_journal',
        orderBy: 'source_revision',
      );
      final updated = jsonDecode(events.last['payload_json'] as String) as Map;
      expect(updated['fine_estimate'], {
        'won': 50000,
        'rule': 'parking',
        'rule_version': fine_estimate.ruleVersion,
      });
      expect(events.last['personal_save_state'], 'saved');
      expect((await store.db.query('outbox')).length, 2);
      // 같은 입력으로 다시 불러도 이벤트가 없다.
      expect(
        (await refreshFineEstimateFor('P1', store: store))?.eventId,
        isNull,
      );
      expect(await resendFineEstimateIfNeeded(store: store), 0);
    } finally {
      await _closeStore(store);
    }
  });

  test('삭제 뒤 새 연결에서도 사진 보충이 삭제 자료를 되살리지 않는다(BL-1, PC와 같음)', () async {
    final store = await _openStore();
    try {
      await LocalDbService.upsertReport(
        _report(id: 'P1', fineInfo: '과태료'),
        'parking',
        '불법주정차신고',
      );
      await _seedOldJournal(store, 'P1', revision: 1);
      await store.db.update('source_journal', {
        'blocked_reason': 'deleted_by_user',
      });
      await store.setContext({
        'contributor_fingerprint': 'fp1',
        'connection_id': '33333333-3333-4333-8333-333333333333',
        'writer_epoch': 2,
        'dataset_key': 'ds1',
        'consent_grant_id': '22222222-2222-4222-8222-222222222222',
        'policy_version': '2026-09-28.1',
        'consent_text_sha256': 'abc',
        'source_app': 'safetyreport-mobile',
        'source_mode': 'standalone',
      });
      expect(
        (await refreshFineEstimateFor('P1', store: store))?.eventId,
        isNull,
      );
      expect(await resendFineEstimateIfNeeded(store: store), 0);
      expect((await store.db.query('source_journal')).length, 1);
      expect(await store.db.query('outbox'), isEmpty);
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
