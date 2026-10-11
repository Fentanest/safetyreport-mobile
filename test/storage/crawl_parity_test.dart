// 서버와 같은 동기화 저장 규칙(2026-09-25): 목록 값 갱신, 만족도 확정 미참여.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/rating_lookup.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report({String poll = '참여 가능', int? rating, String cause = ''}) =>
    Report(
      id: 'p-1',
      reportNumber: 'SPP-2609-0000700',
      name: '신호위반',
      date: '2026-09-01',
      responseDate: '2026-09-10',
      agency: '기관',
      manager: '담당',
      status: '수용',
      result: '답변완료',
      fineInfo: '',
      penaltyPoints: '',
      carNumber: '12가3456',
      law: '',
      location: '서울 강서구 1',
      occurrenceDate: '2026-09-01',
      occurrenceTime: '08:00',
      reportContent: '본문',
      processContent: '처리',
      pollStatus: poll,
      rating: rating,
      ratingCause: cause,
    );

Future<Map<String, Object?>> _row() async =>
    (await (await LocalDbService.db).query(
      'reports',
      where: 'ID = ?',
      whereArgs: ['p-1'],
    )).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_crawl_parity_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });
  const entry = '자동차·교통위반-신호위반';

  test(
    'list rows refresh status and poll of stored reports but never downgrade 참여 완료',
    () async {
      await LocalDbService.upsertReport(_report(), 'traffic', entry);
      // 나중에 사이트에서 별점을 매겼다 → 목록 점수 > 0
      var n = await LocalDbService.updateTitlesFromList([
        {
          'C_NO': 'p-1',
          'C_NOW': 10,
          'STSFDG_SCORE': 5,
          'C_A_TITLE': '(교통) 신호위반',
          'C_DATE': '2026-09-01',
          'STTEMNT_NO': 'SPP-2609-0000700',
        },
        {'C_NO': 'not-stored', 'C_NOW': 10},
      ]);
      expect(n, 1);
      expect((await _row())['만족도조사여부'], '참여 완료');
      // 목록이 참여 가능이라고 해도 되돌리지 않음
      await LocalDbService.updateTitlesFromList([
        {'C_NO': 'p-1', 'C_NOW': 14, 'STSFDG_SCORE': 0},
      ]);
      final row = await _row();
      expect((row['만족도조사여부'], row['상태'], row['신고명']), ('참여 완료', '불수용', '신호위반'));
    },
  );

  test(
    'a confirmed "no survey" lookup resets poll, rating and cause',
    () async {
      await LocalDbService.upsertReport(
        _report(poll: '참여 완료', rating: 3, cause: '늦음'),
        'traffic',
        entry,
        ratingLookup: RatingLookup.found,
      );
      await LocalDbService.upsertReport(
        _report(poll: '참여 완료', rating: 3),
        'traffic',
        entry,
        ratingLookup: RatingLookup.confirmedNone,
      );
      final row = await _row();
      expect((row['만족도조사여부'], row['별점'], row['별점사유']), ('참여 가능', null, ''));
    },
  );

  test('v14 restores the intro only where the old app stripped it', () async {
    await LocalDbService.upsertReport(_report(), 'traffic', entry);
    final d = await LocalDbService.db;
    const intro = '본 신고는 안전신문고 앱의 불법주정차신고-횡단보도 메뉴로 접수된 신고입니다.';
    Future<void> put(String id, String content, String raw) async {
      await d.rawInsert(
        "INSERT OR REPLACE INTO reports(ID, 신고번호, 신고내용, category) VALUES (?, ?, ?, 'parking')",
        [id, 'SPP-$id', content],
      );
      await d.rawInsert(
        "INSERT OR REPLACE INTO report_raw(ID, raw_content, raw_type) VALUES (?, ?, 'report_body')",
        [id, raw],
      );
    }

    await put(
      'stripped',
      '횡단보도 위 주차',
      '$intro\r\n횡단보도 위 주차\r\n* 차량번호 : 12가3456',
    );
    await put(
      'other-path',
      '다른 경로로 만든 신고내용',
      '$intro\n횡단보도 위 주차\n* 차량번호 : 12가3456',
    );
    await put('same', '본문만', '본문만\n* 차량번호 : 1\n$intro');
    expect(await LocalDbService.restoreReportContentFromRawForTest(d), 1);
    Future<String?> content(String id) async =>
        (await d.query(
              'reports',
              columns: ['신고내용'],
              where: 'ID = ?',
              whereArgs: [id],
            )).single['신고내용']
            as String?;
    expect(await content('stripped'), '$intro\n횡단보도 위 주차');
    expect(await content('other-path'), '다른 경로로 만든 신고내용');
    expect(await content('same'), '본문만');
  });

  // ── SSNPC 코드 저장과 분류 재지정(2026-10-11, 앱 DB 17) ──────────────────────
  group('upsertReport 의 SSNPC 코드·분류', () {
    const entryTraffic = '자동차·교통위반-신호위반'; // TV-02, category traffic
    const entryLiving = '생활불편신고-쓰레기, 폐기물'; // DR-06, category living

    test('SSNPC 코드는 정규화되어 저장되고, 코드의 분류가 쓰인다', () async {
      await LocalDbService.upsertReport(
        _report(),
        'traffic',
        entryTraffic,
        ssnpcCd: ' tv ',
        ssnpcType: '2',
      );
      final row = await _row();
      expect(row['ssnpc_cd'], 'TV');
      expect(row['ssnpc_type'], '02');
      expect(row['category'], 'traffic');
    });

    test('코드가 있으면 entry_value 와 분류가 달라도 코드가 이긴다', () async {
      // entry_value 는 교통위반 메뉴지만 코드는 DR-06(생활불편 쓰레기·폐기물) — 코드가 먼저다.
      await LocalDbService.upsertReport(
        _report(),
        'traffic',
        entryTraffic,
        ssnpcCd: 'DR',
        ssnpcType: '06',
      );
      final row = await _row();
      expect(row['category'], 'living');
      expect(row['ssnpc_cd'], 'DR');
      expect(row['ssnpc_type'], '06');
    });

    test('코드 없는 응답은 저장된 코드를 지우지 않는다', () async {
      await LocalDbService.upsertReport(
        _report(),
        'traffic',
        entryTraffic,
        ssnpcCd: 'TV',
        ssnpcType: '02',
      );
      await LocalDbService.upsertReport(
        _report(),
        'traffic',
        entryTraffic,
      ); // 코드 없는 응답(재크롤링 등)
      final row = await _row();
      expect(row['ssnpc_cd'], 'TV', reason: '이번 응답에 코드가 없어도 저장된 코드를 지우지 않는다');
      expect(row['ssnpc_type'], '02');
      expect(row['category'], 'traffic');
    });

    test(
      '처음 채워지는 코드는 분류가 그대로면 변경으로 세지 않는다(17 변환 직후 가짜 변경 방지)',
      () async {
        final first = await LocalDbService.upsertReport(
          _report(),
          'traffic',
          entryTraffic,
        );
        expect(first.isNew, isTrue);
        final second = await LocalDbService.upsertReport(
          _report(),
          'traffic',
          entryTraffic,
          ssnpcCd: 'TV',
          ssnpcType: '02', // entry_value 와 같은 분류(traffic)라 category 는 바뀌지 않는다
        );
        expect(second.isNew, isFalse);
        expect(
          second.changed,
          isFalse,
          reason: '이전 값이 없던 ssnpc_cd·ssnpc_type 이 처음 채워지는 것만으로는 변경이 아니다',
        );
      },
    );

    test('이미 저장된 코드가 바뀌면 분류가 같아도 변경으로 센다', () async {
      await LocalDbService.upsertReport(
        _report(),
        'traffic',
        entryTraffic,
        ssnpcCd: 'TV',
        ssnpcType: '02',
      );
      final changedResult = await LocalDbService.upsertReport(
        _report(),
        'traffic',
        entryTraffic,
        ssnpcCd: 'TV',
        ssnpcType: '09', // 같은 traffic 분류(기타 자동차 안전기준 위반)지만 코드 자체는 바뀐다
      );
      expect(
        changedResult.changed,
        isTrue,
        reason: '이전 값이 있던 ssnpc_type 이 바뀌면 분류가 같아도 변경이다',
      );
      expect((await _row())['ssnpc_type'], '09');
    });

    test('category 가 바뀌면 변경으로 센다', () async {
      await LocalDbService.upsertReport(_report(), 'traffic', entryTraffic);
      final changedResult = await LocalDbService.upsertReport(
        _report(),
        'living',
        entryLiving,
      );
      expect(changedResult.changed, isTrue);
      expect((await _row())['category'], 'living');
    });
  });
}
