// 업데이트 뒤 한 번 훑기(주정차 사진 촬영 시각) — 서버 tests/test_maintenance_service.py 와 같은 규칙.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/maintenance_service.dart';
import 'package:safetyreport/services/photo_capture_time.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/maintenance_status_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _daysAgo(int days) {
  final d = DateTime.now().subtract(Duration(days: days));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

Report _report(String id, {required String date, String photos = ''}) => Report(
  id: id,
  reportNumber: 'SPP-2609-$id',
  name: '불법주정차신고',
  date: date,
  responseDate: '',
  agency: '',
  manager: '',
  status: '처리중',
  result: '처리중',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
  attachedPhotos: photos,
);

Future<void> _resetDb() async {
  MaintenanceService.resetForTest();
  await LocalDbService.closeDb();
  final dbPath = await LocalDbService.getDbPath();
  await deleteDatabase(dbPath);
  for (final ext in ['-wal', '-shm']) {
    final sidecar = File('$dbPath$ext');
    if (sidecar.existsSync()) await sidecar.delete();
  }
}

Future<Map<String, Object?>> _row(String id) async {
  final d = await LocalDbService.db;
  return (await d.query('reports', where: 'ID = ?', whereArgs: [id])).single;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDbDir = Directory.systemTemp.createTempSync('sr_maintenance_test_');
    await databaseFactory.setDatabasesPath(tempDbDir.path);
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _resetDb();
  });
  tearDown(_resetDb);

  Future<void> seed() async {
    const entry = '불법주정차신고-기타 불법주정차';
    // 대상: 6개월 이내 + 사진 URL + 아직 안 읽음
    await LocalDbService.upsertReport(
      _report(
        '1',
        date: _daysAgo(10),
        photos: 'https://x/a.jpg\nhttps://x/b.jpg',
      ),
      'parking',
      entry,
    );
    await LocalDbService.upsertReport(
      _report('2', date: _daysAgo(20), photos: 'https://x/c.jpg'),
      'parking',
      entry,
    );
    // 제외: 6개월 넘음(URL 만료), 사진 없음, 주정차 아님
    await LocalDbService.upsertReport(
      _report('3', date: _daysAgo(220), photos: 'https://x/d.jpg'),
      'parking',
      entry,
    );
    await LocalDbService.upsertReport(
      _report('4', date: _daysAgo(5)),
      'parking',
      entry,
    );
    await LocalDbService.upsertReport(
      _report('5', date: _daysAgo(5), photos: 'https://x/e.jpg'),
      'traffic',
      '자동차·교통위반-신호위반',
    );
  }

  test(
    'pendingPhotoRows picks recent parking reports with photos not yet read',
    () async {
      await seed();
      final rows = await LocalDbService.pendingPhotoRows();
      expect(rows.map((r) => r.id).toList(), ['2', '1']);
      expect(rows.last.reportNumber, 'SPP-2609-1');
    },
  );

  test(
    'backfill fills capture times, then the rows drop out of the pass',
    () async {
      await seed();
      final times = {
        'https://x/a.jpg': '2026-09-20 23:10:00',
        'https://x/b.jpg': '2026-09-21 07:40:00',
        'https://x/c.jpg': null, // EXIF 없음 → count 0, 다시 시도하지 않음
      };
      await MaintenanceService.startPhotoBackfill(
        fetch: (url) async => times[url],
        interval: Duration.zero,
        syncing: () => false,
        wait: true,
      );
      final one = await _row('1');
      expect(one['사진_첫촬영'], '2026-09-20 23:10:00');
      expect(one['사진_끝촬영'], '2026-09-21 07:40:00');
      expect(one['사진_촬영수'], 2);
      expect((await _row('2'))['사진_촬영수'], 0);
      expect((await _row('3'))['사진_촬영수'], isNull);

      final job = MaintenanceService.photoJob.value!;
      expect(job.state, 'completed');
      expect(job.done, 2);
      expect(job.message, '2건 채움');
      expect(await LocalDbService.pendingPhotoRows(), isEmpty);
    },
  );

  test('network errors leave the report for next time', () async {
    await seed();
    await MaintenanceService.startPhotoBackfill(
      fetch: (url) async =>
          url.endsWith('c.jpg') ? throw Exception('timeout') : null,
      interval: Duration.zero,
      syncing: () => false,
      wait: true,
    );
    expect((await _row('2'))['사진_촬영수'], isNull);
    expect(MaintenanceService.photoJob.value!.message, '1건 채움, 1건은 다음에 다시');
    expect((await LocalDbService.pendingPhotoRows()).map((r) => r.id), ['2']);
  });

  test('waits while a sync is running, then continues', () async {
    await seed();
    var syncChecks = 0;
    final states = <String>[];
    void listen() => states.add(MaintenanceService.photoJob.value?.state ?? '');
    MaintenanceService.photoJob.addListener(listen);
    await MaintenanceService.startPhotoBackfill(
      fetch: (url) async => null,
      interval: Duration.zero,
      syncWait: const Duration(milliseconds: 5),
      syncing: () => ++syncChecks <= 2,
      wait: true,
    );
    MaintenanceService.photoJob.removeListener(listen);
    expect(states, contains('paused'));
    expect(states.last, 'completed');
  });

  test('nothing to do leaves no job', () async {
    await MaintenanceService.startPhotoBackfill(
      fetch: (_) async => null,
      wait: true,
    );
    expect(MaintenanceService.photoJob.value, isNull);
    expect(MaintenanceService.localJobs(), isEmpty);
  });

  group('same call sites as the server crawl', () {
    const entry = '불법주정차신고-기타 불법주정차';
    Future<String?> fetch(String url) async => '2026-09-20 23:10:00';

    test('save-time capture: parking reports not yet read', () async {
      // 새 신고(아직 행 없음)도 대상 — 서버 _prefetch_derived 와 같음
      final fresh = await MaintenanceService.prefetchForSave(
        '1',
        'parking',
        entry,
        'https://x/a.jpg',
        fetch: fetch,
      );
      expect(fresh?.count, 1);
      await LocalDbService.upsertReport(
        _report('1', date: _daysAgo(3), photos: 'https://x/a.jpg'),
        'parking',
        entry,
        photoCapture: fresh,
      );
      final row = await _row('1');
      expect(row['사진_첫촬영'], '2026-09-20 23:10:00');
      expect(row['사진_촬영수'], 1);

      // 이미 읽은 신고는 다시 받지 않고, 재저장해도 값을 이어받는다
      expect(
        await MaintenanceService.prefetchForSave(
          '1',
          'parking',
          entry,
          'https://x/a.jpg',
          fetch: (_) async => throw StateError('should not fetch'),
        ),
        isNull,
      );
      await LocalDbService.upsertReport(
        _report('1', date: _daysAgo(3), photos: 'https://x/a.jpg'),
        'parking',
        entry,
        photoCapture: const PhotoCapture(first: 'x', last: 'x', count: 9),
      );
      expect((await _row('1'))['사진_촬영수'], 1);
    });

    test('save-time capture skips non-parking and survives errors', () async {
      expect(
        await MaintenanceService.prefetchForSave(
          '5',
          'traffic',
          '자동차·교통위반-신호위반',
          'https://x/e.jpg',
          fetch: fetch,
        ),
        isNull,
      );
      expect(
        await MaintenanceService.prefetchForSave(
          '6',
          'parking',
          entry,
          'https://x/f.jpg',
          fetch: (_) async => throw Exception('timeout'),
        ),
        isNull,
      );
    });

    test('end-of-sync retry takes the newest [limit] rows', () async {
      await seed();
      final filled = await MaintenanceService.backfillMissing(
        limit: 1,
        fetch: fetch,
      );
      expect(filled, 1);
      expect((await _row('2'))['사진_촬영수'], 1);
      expect((await _row('1'))['사진_촬영수'], isNull);
    });
  });

  test('jobsFromServer reads the server status payload', () {
    final jobs = MaintenanceService.jobsFromServer({
      'active': true,
      'jobs': [
        {
          'key': 'photo_capture_time',
          'label': '주정차 사진 촬영 시각 읽기',
          'state': 'running',
          'total': 480,
          'done': 132,
          'current': 'SPP-2609-1',
          'message': '',
          'filled': 120,
        },
      ],
    });
    expect(jobs.single.active, isTrue);
    expect(jobs.single.line, '주정차 사진 촬영 시각 읽기 · 132/480 · SPP-2609-1');
    expect(MaintenanceService.jobsFromServer(null), isEmpty);
  });

  group('MaintenanceStatusBar', () {
    Widget host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(bottomNavigationBar: child),
    );

    testWidgets('shows server progress, then 완료 briefly, then hides', (
      tester,
    ) async {
      var status = <String, dynamic>{
        'active': true,
        'jobs': [
          {
            'key': 'photo_capture_time',
            'label': '주정차 사진 촬영 시각 읽기',
            'state': 'running',
            'total': 10,
            'done': 3,
            'current': 'SPP-1',
            'message': '',
          },
        ],
      };
      await tester.pumpWidget(
        host(MaintenanceStatusBar(fetchServerStatus: () async => status)),
      );
      await tester.pump();
      expect(find.byKey(const Key('maintenance-status-bar')), findsOneWidget);
      expect(find.textContaining('3/10'), findsOneWidget);
      expect(find.byType(BusyRing), findsOneWidget);

      status = {
        'active': false,
        'jobs': [
          {
            'key': 'photo_capture_time',
            'label': '주정차 사진 촬영 시각 읽기',
            'state': 'completed',
            'total': 10,
            'done': 10,
            'message': '9건 채움, 1건은 다음에 다시',
          },
        ],
      };
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        find.text('주정차 사진 촬영 시각 읽기 완료 · 9건 채움, 1건은 다음에 다시'),
        findsOneWidget,
      );
      expect(find.byType(BusyRing), findsNothing);

      await tester.pump(const Duration(seconds: 7));
      expect(find.byKey(const Key('maintenance-status-bar')), findsNothing);
      await tester.pumpWidget(const SizedBox()); // 타이머 정리
    });

    testWidgets('old server (null status) draws nothing', (tester) async {
      await tester.pumpWidget(
        host(MaintenanceStatusBar(fetchServerStatus: () async => null)),
      );
      await tester.pump();
      expect(find.byKey(const Key('maintenance-status-bar')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('standalone follows the local photo job', (tester) async {
      await tester.pumpWidget(host(const MaintenanceStatusBar()));
      await tester.pump();
      expect(find.byKey(const Key('maintenance-status-bar')), findsNothing);
      MaintenanceService.photoJob.value = const MaintenanceJob(
        key: MaintenanceService.photoJobKey,
        label: MaintenanceService.photoJobLabel,
        state: 'paused',
        total: 5,
        done: 1,
        message: '동기화가 끝나면 이어서 합니다',
      );
      await tester.pump();
      expect(find.textContaining('동기화가 끝나면'), findsOneWidget);
      MaintenanceService.photoJob.value = null;
      await tester.pumpWidget(const SizedBox());
    });
  });
  group('사진 보충 뒤 공유 추정 갱신(서버 photo_capture_time.fill_one 과 같은 자리)', () {
    Future<String?> fetchTimes(String url) async =>
        url.endsWith('a.jpg') ? '2026-09-01 10:00:00' : '2026-09-01 12:01:00';

    test('촬영 시각을 저장한 신고만 공유 추정을 다시 계산한다', () async {
      await seed();
      final refreshed = <String>[];
      MaintenanceService.refreshSharedEstimateForTest = (id) async =>
          refreshed.add(id);
      expect(await MaintenanceService.backfillMissing(fetch: fetchTimes), 2);
      expect(refreshed, ['2', '1']);
      // 네트워크 오류(촬영 시각 못 읽음)면 저장도 갱신도 하지 않는다.
      refreshed.clear();
      await _resetDb();
      await seed();
      MaintenanceService.refreshSharedEstimateForTest = (id) async =>
          refreshed.add(id);
      expect(
        await MaintenanceService.backfillMissing(
          fetch: (_) async => throw const SocketException('offline'),
        ),
        0,
      );
      expect(refreshed, isEmpty);
    });

    test('공유 캡처가 실패해도 촬영 시각은 남기고 재시도 의도를 기록한다', () async {
      await seed();
      final queued = <String>[];
      var downloads = 0;
      MaintenanceService.refreshSharedEstimateForTest = (_) async =>
          throw StateError('journal unavailable');
      MaintenanceService.queueRetryForTest = (id, reason) async =>
          queued.add('$id:$reason');
      Future<String?> counting(String url) {
        downloads++;
        return fetchTimes(url);
      }

      expect(await MaintenanceService.backfillMissing(fetch: counting), 2);
      expect(queued, [
        '2:${MaintenanceService.photoBackfillRetryReason}',
        '1:${MaintenanceService.photoBackfillRetryReason}',
      ]);
      expect((await _row('1'))['사진_촬영수'], 2);
      expect((await _row('1'))['사진_첫촬영'], '2026-09-01 10:00:00');
      // 다음 훑기 대상이 아니므로 같은 사진을 다시 내려받지 않는다.
      expect(await LocalDbService.pendingPhotoRows(), isEmpty);
      expect(await MaintenanceService.backfillMissing(fetch: counting), 0);
      expect(downloads, 3);
    });

    test('읽는 동안 첨부가 바뀌면 다른 사진의 촬영 시각을 저장하지 않는다(PC fill_one 과 같음)', () async {
      await seed();
      final refreshed = <String>[];
      MaintenanceService.refreshSharedEstimateForTest = (id) async =>
          refreshed.add(id);
      Future<String?> swapDuringFetch(String url) async {
        // 네트워크를 기다리는 동안 재동기화가 신고 1의 첨부를 새 사진으로 바꾼 상황.
        final d = await LocalDbService.db;
        await d.update(
          'reports',
          {'첨부사진': 'https://x/new.jpg'},
          where: 'ID = ?',
          whereArgs: ['1'],
        );
        return fetchTimes(url);
      }

      expect(
        await MaintenanceService.backfillMissing(fetch: swapDuringFetch),
        1,
      );
      expect((await _row('1'))['사진_촬영수'], isNull);
      expect(refreshed, ['2']);
      // 다음 훑기에서 새 첨부로 다시 시도한다.
      expect(
        (await LocalDbService.pendingPhotoRows()).map((r) => r.photos),
        ['https://x/new.jpg'],
      );
    });

    test('재시도 의도 기록까지 실패해도 촬영 시각은 남는다', () async {
      await seed();
      MaintenanceService.refreshSharedEstimateForTest = (_) async =>
          throw StateError('journal unavailable');
      MaintenanceService.queueRetryForTest = (_, _) async =>
          throw const FileSystemException('disk full');
      expect(await MaintenanceService.backfillMissing(fetch: fetchTimes), 2);
      expect((await _row('2'))['사진_촬영수'], 1);
    });
  });
}

