// 별점 공통 사유(G16 W2) — 서버 tests/test_rating_eligibility.py 와 같은 규칙·흐름.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/rating_batch_result.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/rating_service.dart';
import 'package:safetyreport/services/standalone_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef Site = ({int? score, String cause, bool confirmed, bool exists});

Report _report(String number) => Report(
  id: number.replaceAll(RegExp(r'\D'), ''),
  reportNumber: number,
  name: '테스트',
  date: '2026-09-01',
  responseDate: '2026-09-10',
  agency: '',
  manager: '',
  status: '수용',
  result: '수용',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
  pollStatus: '참여 가능',
);

Site site(int score, [String cause = '']) =>
    (score: score, cause: cause, confirmed: true, exists: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final doc =
      jsonDecode(
            File(
              'contracts/rating-eligibility-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('shared cause vectors (same as server)', () {
    expect(doc['rating_cause_max'], RatingService.ratingCauseMax);
    for (final raw in doc['cause_cases'] as List) {
      final c = raw as Map<String, dynamic>;
      String? input = c['input'] as String?;
      if (input != null && c['repeat'] != null) {
        input = input * (c['repeat'] as int);
      }
      final normalized = RatingService.normalizeCause(input);
      if (c.containsKey('normalized')) {
        expect(normalized, c['normalized'], reason: '$c');
      } else {
        expect(normalized.runes.length, c['normalized_length']);
      }
      expect(RatingService.causeError(input) != null, c['too_long']);
    }
  });

  test('shared popup cause vectors (same as server)', () {
    for (final raw in doc['popup_cases'] as List) {
      final c = raw as Map<String, dynamic>;
      expect(
        StandaloneApiService.extractCauseFromPopupHtmlForTest(
          c['html'] as String,
        ),
        c['cause'],
        reason: c['html'] as String,
      );
    }
  });

  group('standalone submit flow', () {
    late Directory dir;
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      dir = Directory.systemTemp.createTempSync('sr_rating_cause_');
      await databaseFactory.setDatabasesPath(dir.path);
    });
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await LocalDbService.closeDb();
      await deleteDatabase(await LocalDbService.getDbPath());
      await LocalDbService.upsertReport(
        _report('SPP-9'),
        'traffic',
        '자동차·교통위반-신호위반',
      );
    });
    tearDownAll(() async {
      await LocalDbService.closeDb();
      dir.deleteSync(recursive: true);
    });

    Future<Map<String, Object?>> row() async {
      final d = await LocalDbService.db;
      return (await d.query(
        'reports',
        where: '신고번호 = ?',
        whereArgs: ['SPP-9'],
      )).single;
    }

    Future<(List<RatingBatchItem>, List<(int, String)>)> run(
      List<Site> answers, {
      String cause = '감사합니다',
    }) async {
      final queue = [...answers];
      final posts = <(int, String)>[];
      final items = await RatingService.submitStandaloneForTest(
        [_report('SPP-9')],
        4,
        cause,
        lookup: (_) async => queue.isEmpty ? site(0) : queue.removeAt(0),
        post: (spp, score, c) async => posts.add((score, c)),
      );
      return (items, posts);
    }

    test(
      'cause is sent and success needs the site to show the score',
      () async {
        final (items, posts) = await run([
          site(0),
          site(4, '감사합니다'),
        ], cause: '  감사합니다\r\n');
        expect(posts, [(4, '감사합니다')]);
        expect(items.single.status, RatingBatchItemStatus.success);
        final r = await row();
        expect(r['별점'], 4);
        expect(r['별점사유'], '감사합니다');
        expect(r['만족도조사여부'], '참여 완료');
      },
    );

    test('unconfirmed submit is retried and counted once confirmed', () async {
      final (items, posts) = await run([
        site(0), // 사전 확인
        site(0), // 제출 뒤 확인 — 아직 안 보임
        site(4, '감사합니다'), // 재시도의 사전 확인
      ]);
      expect(posts, hasLength(1));
      expect(items.single.status, RatingBatchItemStatus.success);
    });

    test('never confirmed is a failure, nothing saved', () async {
      final (items, posts) = await run(List.filled(8, site(0)));
      expect(posts, hasLength(1)); // 재시도에서 다시 제출하지 않는다(중복 제출 방지)
      expect(items.single.status, RatingBatchItemStatus.failure);
      expect(items.single.message, contains('제출 후 사이트에서 점수를 확인하지 못했습니다'));
      expect((await row())['별점'], isNull);
    });

    test(
      'missing site record fails without submitting (like server)',
      () async {
        final (items, posts) = await run([
          (score: null, cause: '', confirmed: true, exists: false),
        ]);
        expect(posts, isEmpty);
        expect(items.single.status, RatingBatchItemStatus.failure);
        expect(items.single.message, contains('대상 신고건이 없거나'));
      },
    );

    test('already rated on site is a skip with the site values', () async {
      final (items, posts) = await run([site(5, '예전 사유')]);
      expect(posts, isEmpty);
      expect(items.single.status, RatingBatchItemStatus.skip);
      expect((await row())['별점사유'], '예전 사유');
    });

    test('site dropping the cause is noted and the site value saved', () async {
      final (items, _) = await run([site(0), site(4, '')]);
      expect(items.single.status, RatingBatchItemStatus.success);
      expect(items.single.message, contains('사이트에 저장된 사유가 보낸 사유와 다릅니다'));
      expect((await row())['별점사유'], '');
    });
  });
}
