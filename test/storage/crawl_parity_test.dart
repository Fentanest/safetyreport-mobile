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
}
