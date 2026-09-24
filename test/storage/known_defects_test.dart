// 저장 계층의 알려진 결함을 '현재 동작'으로 고정한다 (저장 계층 재설계 R0, 서버 레포 docs/plans/storage-refactor-plan.md §2-2).
// 각 테스트는 지금의 잘못된 동작을 확인한다. 해당 단계(R3 등)에서 고치면 실패한다 — 그때 기대값을 올바른 동작으로 뒤집고
// 이름의 'currently' 를 떼어 회귀 테스트로 바꾼다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/rating_lookup.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Report _report({
  String id = 'k-1',
  String reportNumber = 'SPP-2609-0000100',
  String processContent = '사이트 처리내용',
  String pollStatus = '참여 가능',
  int? rating,
  String ratingCause = '',
}) => Report(
  id: id,
  reportNumber: reportNumber,
  name: '신호위반',
  date: '2026-09-01',
  responseDate: '2026-09-10',
  agency: '서울특별시 강서경찰서 교통과',
  manager: '김담당',
  status: '수용',
  result: '수용',
  fineInfo: '과태료',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '도로교통법 제5조',
  location: '서울특별시 강서구 마곡동 1',
  occurrenceDate: '2026-09-01',
  occurrenceTime: '08:00',
  reportContent: '신고 내용',
  processContent: processContent,
  pollStatus: pollStatus,
  rating: rating,
  ratingCause: ratingCause,
);

Future<Map<String, Object?>> _row(String id) async =>
    (await (await LocalDbService.db).query(
      'reports',
      where: 'ID = ?',
      whereArgs: [id],
    )).single;

Future<void> _reset() async {
  await LocalDbService.closeDb();
  final path = await LocalDbService.getDbPath();
  await deleteDatabase(path);
  for (final ext in ['-wal', '-shm']) {
    final f = File('$path$ext');
    if (f.existsSync()) await f.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_known_defects_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _reset();
  });
  tearDownAll(() async {
    await _reset();
    dir.deleteSync(recursive: true);
  });

  const entry = '자동차·교통위반-신호위반';

  test(
    'M-2/M-3 fixed (R3, 결정 D-2·D-3): a refetch without satisfaction data keeps rating, cause and completed poll',
    () async {
      await LocalDbService.upsertReport(
        _report(pollStatus: '참여 완료', rating: 2, ratingCause: '답변이 늦음'),
        'traffic',
        entry,
        ratingLookup: RatingLookup.found,
      );
      // 재조회에서 사이트 점수가 비어 있으면(조회 안 함) 기존 값을 지키고 '참여 완료' 를 되돌리지 않는다.
      await LocalDbService.upsertReport(
        _report(pollStatus: '참여 가능'),
        'traffic',
        entry,
      );
      var row = await _row('k-1');
      expect((row['별점'], row['별점사유'], row['만족도조사여부']), (2, '답변이 늦음', '참여 완료'));

      // 조회 실패: 사이트 점수는 쓰되 사유는 유지
      await LocalDbService.upsertReport(
        _report(pollStatus: '참여 완료', rating: 3),
        'traffic',
        entry,
        ratingLookup: RatingLookup.failed,
      );
      row = await _row('k-1');
      expect((row['별점'], row['별점사유']), (3, '답변이 늦음'));

      // 조회 성공: 사이트 값 그대로
      await LocalDbService.upsertReport(
        _report(pollStatus: '참여 완료', rating: 5, ratingCause: ''),
        'traffic',
        entry,
        ratingLookup: RatingLookup.found,
      );
      row = await _row('k-1');
      expect((row['별점'], row['별점사유']), (5, ''));
    },
  );

  test(
    'refetch keeps identity fields when the parser returns empty ones',
    () async {
      await LocalDbService.upsertReport(_report(), 'traffic', entry);
      final blank = Report(
        id: 'k-1',
        reportNumber: '',
        name: '',
        date: '',
        responseDate: '',
        agency: '',
        manager: '',
        status: '수용',
        result: '',
        fineInfo: '',
        penaltyPoints: '',
        carNumber: '',
        law: '',
        location: '',
        occurrenceDate: '',
        occurrenceTime: '',
        reportContent: '',
        processContent: '',
      );
      await LocalDbService.upsertReport(blank, 'traffic', entry);
      final row = await _row('k-1');
      expect(
        (row['신고번호'], row['신고명'], row['신고일'], row['상태']),
        ('SPP-2609-0000100', '신호위반', '2026-09-01', '수용'),
      );
    },
  );

  test(
    'M-12 fixed (R3, 결정 D-1): a manual edit survives a refetch and the site original is kept',
    () async {
      await LocalDbService.upsertReport(_report(), 'traffic', entry);
      await LocalDbService.updateEditableRecord('k-1', {
        '처리내용': '내가 고친 처리내용',
        '처리기관': '서울특별시 강서경찰서 교통과',
      });
      Future<Map<String, Object?>> shown() async =>
          (await (await LocalDbService.db).query(
            LocalDbService.effectiveReportsView,
            where: 'ID = ?',
            whereArgs: ['k-1'],
          )).single;
      expect((await shown())['처리내용'], '내가 고친 처리내용');
      await LocalDbService.upsertReport(_report(), 'traffic', entry);
      expect((await shown())['처리내용'], '내가 고친 처리내용');
      expect((await _row('k-1'))['처리내용'], '사이트 처리내용'); // 원본은 원본대로
      final overrides = await (await LocalDbService.db).query(
        'report_override',
      );
      expect(overrides.map((r) => r['column_name']), [
        '처리내용',
      ]); // 원본과 같은 값은 수정값을 만들지 않음
      expect(
        (await LocalDbService.getReport('k-1'))!.processContent,
        '내가 고친 처리내용',
      );
    },
  );

  test(
    'M-1 (R3, 결정 D-6): currently clearAll (used by full resync) drops watchlist and geocode cache',
    () async {
      await LocalDbService.upsertReport(_report(), 'traffic', entry);
      await LocalDbService.setWatchlistNumbers({'SPP-2609-0000100'});
      final d = await LocalDbService.db;
      await d.insert('geocode_cache', {
        '주소정규화': '서울특별시 강서구 마곡동 1',
        '상태': 'ok',
        'source': 'kakao',
        '위도': 37.5,
        '경도': 126.8,
      });
      await LocalDbService.clearAll();
      expect(await LocalDbService.getWatchlistNumbers(), isEmpty);
      expect(await (await LocalDbService.db).query('geocode_cache'), isEmpty);
    },
  );

  test(
    'M-24 (R3, 결정 D-7): currently the demo seed replaces the real reports',
    () async {
      await LocalDbService.upsertReport(_report(), 'traffic', entry);
      await LocalDbService.seedPlayReviewDemo();
      final ids = (await (await LocalDbService.db).query(
        'reports',
        columns: ['ID'],
      )).map((r) => r['ID']).toSet();
      expect(ids.contains('k-1'), isFalse);
      expect(ids, isNotEmpty);
    },
  );
}
