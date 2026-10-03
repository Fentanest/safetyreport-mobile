import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/duplicate_projection_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;

import '../../tool/large_data_fixture.dart';
import '../support/legacy_duplicate_rebuild.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_duplicate_bounded_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDownAll(() async {
    PerformanceTrace.observer = null;
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  test(
    'SQL rebuild matches legacy normalization, rank, conflict, decisions, legacy fingerprint and alerts',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 3000, giantRawGroups: true);
      // CRLF/whitespace normalization, blank raw, legacy-group migration and manual choice.
      await db.update(
        'report_raw',
        {'raw_content': ' \r\n동일\t 원문\r\n\n '},
        where: 'ID=?',
        whereArgs: ['fixture-000000001'],
      );
      await db.update(
        'report_raw',
        {'raw_content': '동일 원문'},
        where: 'ID=?',
        whereArgs: ['fixture-000000002'],
      );
      await db.update(
        'report_raw',
        {'raw_content': '\t \n'},
        where: 'ID=?',
        whereArgs: ['fixture-000000003'],
      );
      await LegacyDuplicateRebuild.refreshDuplicateGroups(db);
      final manual = (await db.query(
        'duplicate_group',
        orderBy: 'member_count ASC',
      )).first;
      await DuplicateProjectionService.updateDuplicateGroup(
        db,
        manual['group_id'] as String,
        representativeId: 'fixture-000000001',
        representativeMode: 'manual',
        duplicateStatus: 'not_duplicate',
        note: '판단 유지',
      );
      final beforeGroups = await db.query(
        'duplicate_group',
        orderBy: 'group_id',
      );
      final beforeMembers = await db.query(
        'duplicate_member',
        orderBy: 'group_id,report_id',
      );
      final result = await DuplicateProjectionService.refreshDuplicateGroups(
        db,
        trackChanges: true,
      );
      expect(result['changes'], isEmpty);
      Map<String, Object?> clean(Map<String, Object?> r) =>
          Map.of(r)..remove('updated_at');
      expect(
        (await db.query(
          'duplicate_group',
          orderBy: 'group_id',
        )).map(clean).toList(),
        beforeGroups.map(clean).toList(),
      );
      expect(
        (await db.query(
          'duplicate_member',
          orderBy: 'group_id,report_id',
        )).map(clean).toList(),
        beforeMembers.map(clean).toList(),
      );
      // Same-count source replacement changes membership even with warm digests.
      await db.update(
        'report_raw',
        {'raw_content': '새 원문'},
        where: 'ID=?',
        whereArgs: ['fixture-000000004'],
      );
      final changed = await DuplicateProjectionService.refreshDuplicateGroups(
        db,
        trackChanges: true,
      );
      expect(
        (changed['changes'] as List).any(
          (e) => e['duplicate_change_type'] == 'members_changed',
        ),
        isTrue,
      );
      for (final e in changed['changes'] as List) {
        expect(e['members'], isEmpty);
        expect(e['members_deferred'], isTrue);
        expect(e['representative'].containsKey('raw_content'), isFalse);
        expect(e['representative'].containsKey('신고내용'), isFalse);
      }
      final expectedGroups = await db.query(
        'duplicate_group',
        orderBy: 'group_id',
      );
      final expectedMembers = await db.query(
        'duplicate_member',
        orderBy: 'group_id,report_id',
      );
      await LegacyDuplicateRebuild.refreshDuplicateGroups(db);
      expect(
        (await db.query(
          'duplicate_group',
          orderBy: 'group_id',
        )).map(clean).toList(),
        expectedGroups.map(clean).toList(),
      );
      expect(
        (await db.query(
          'duplicate_member',
          orderBy: 'group_id,report_id',
        )).map(clean).toList(),
        expectedMembers.map(clean).toList(),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'legacy FNV group IDs preserve normalized decisions and creation time',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 12, giantRawGroups: true);
      await DuplicateProjectionService.refreshDuplicateGroups(db);
      final original = (await db.query('duplicate_group')).single;
      final canonical = original['group_id'] as String;
      final legacy = (await db.rawQuery(
        'SELECT legacy_hash FROM sr_duplicate_input_v1 WHERE payload_hash=? LIMIT 1',
        [canonical],
      )).single['legacy_hash'];
      final oldGroup = {
        ...original,
        'group_id': legacy,
        'fingerprint': legacy,
        'status': 'confirmed',
        'representative_mode': '',
        'representative_id': 'fixture-000000001',
        'note': '옛 판단',
        'created_at': 111,
      };
      final oldMembers = (await db.query(
        'duplicate_member',
      )).map((m) => {...m, 'group_id': legacy}).toList();
      Future<void> reset() async {
        await db.delete('duplicate_member');
        await db.delete('duplicate_group');
        await db.insert('duplicate_group', oldGroup);
        final batch = db.batch();
        for (final m in oldMembers) {
          batch.insert('duplicate_member', m);
        }
        await batch.commit(noResult: true);
      }

      await reset();
      await LegacyDuplicateRebuild.refreshDuplicateGroups(db);
      final expected = (await db.query('duplicate_group')).single;
      final members = await db.query('duplicate_member', orderBy: 'report_id');
      await reset();
      await DuplicateProjectionService.refreshDuplicateGroups(db);
      Map<String, Object?> clean(Map<String, Object?> r) =>
          Map.of(r)..remove('updated_at');
      expect(
        clean((await db.query('duplicate_group')).single),
        clean(expected),
      );
      expect(expected['created_at'], 111);
      expect(expected['representative_mode'], 'manual');
      expect(
        (await db.query(
          'duplicate_member',
          orderBy: 'report_id',
        )).map((r) => clean(r)..remove('created_at')).toList(),
        members.map((r) => clean(r)..remove('created_at')).toList(),
      );
    },
  );

  test(
    'empty projection is completed; external writers invalidate digests and staged revisions',
    () async {
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 1);
      expect(
        (await DuplicateProjectionService.refreshDuplicateGroups(
          db,
        ))['group_count'],
        0,
      );
      expect(
        await DuplicateProjectionService.hasCompletedProjection(db),
        isTrue,
      );
      await seedLargeDataFixture(db, 3000, giantRawGroups: true);
      var edited = false;
      Future<void>? edit;
      final digests = <int>[];
      PerformanceTrace.observer = (e) {
        if (e['stage'] == 'duplicate.digest') digests.add(e['rows'] as int);
        if (!edited && e['stage'] == 'duplicate.field_page') {
          edited = true;
          edit = Future<void>(() async {
            final writer = await openDatabase(db.path, singleInstance: false);
            try {
              await writer.update(
                'report_raw',
                {'raw_content': '계산 중 외부 연결 수정'},
                where: 'ID=?',
                whereArgs: ['fixture-000000000'],
              );
            } finally {
              await writer.close();
            }
          });
        }
      };
      final result = await DuplicateProjectionService.refreshDuplicateGroups(
        db,
      );
      await edit;
      PerformanceTrace.observer = null;
      expect(result['member_count'], 2999);
      expect(digests.fold<int>(0, (a, b) => a + b), 3001);
      expect(
        await db.rawQuery(
          "SELECT 1 FROM duplicate_member WHERE report_id='fixture-000000000'",
        ),
        isEmpty,
      );
      expect(
        await DuplicateProjectionService.hasCompletedProjection(db),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'bounded raw pages, giant group, interleaved summary/edit and warm invalidation',
    () async {
      final n = Platform.environment['SR_LARGE_TEST'] == '1' ? 500000 : 3000;
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, n, giantRawGroups: true);
      final events = <Map<String, Object?>>[];
      final reads = <Future<void>>[];
      var submitted = false;
      var publishedReadStarted = false;
      var publishedReadFinished = false;
      PerformanceTrace.observer = (e) {
        events.add(e);
        if (!publishedReadStarted && e['stage'] == 'duplicate.field_page') {
          publishedReadStarted = true;
          reads.add(
            Future<void>(() async {
              final s = await LocalDbService.computeSummary(
                excludeWithdraw: true,
              );
              expect(s.total, n);
              publishedReadFinished = true;
            }),
          );
        }
        if (e['stage'] == 'duplicate.rebuild') {
          expect(publishedReadFinished, isTrue);
        }
        if (!submitted && e['stage'] == 'duplicate.sql_page') {
          submitted = true;
          reads.add(
            Future<void>(() async {
              final s = await LocalDbService.computeSummary();
              expect(s.total, n);
              await db.update(
                'report_raw',
                {'raw_content': '동시 수정 원문'},
                where: 'ID=?',
                whereArgs: ['fixture-000000000'],
              );
            }),
          );
        }
      };
      final timer = Stopwatch()..start();
      final first = await DuplicateProjectionService.refreshDuplicateGroups(db);
      await Future.wait(reads);
      final coldMs = timer.elapsedMilliseconds;
      expect(publishedReadStarted, isTrue);
      final groups = await DuplicateProjectionService.getDuplicateGroups(db);
      expect(groups.length, 2);
      expect(groups.every((g) => g.members.length <= 50), isTrue);
      final g = groups.first;
      expect(g.memberCount, greaterThan(50));
      final next = await DuplicateProjectionService.getDuplicateMembers(
        db,
        g.groupId,
        page: 1,
      );
      expect(next.length, 50);
      expect(
        next
            .map((m) => m.reportId)
            .toSet()
            .intersection(g.members.map((m) => m.reportId).toSet()),
        isEmpty,
      );
      final selected = next.last.reportId;
      await DuplicateProjectionService.updateDuplicateGroup(
        db,
        g.groupId,
        representativeId: selected,
        representativeMode: 'manual',
        duplicateStatus: g.status,
        note: '페이지 후보 선택',
      );
      expect(
        (await db.query(
          'duplicate_group',
          where: 'group_id=?',
          whereArgs: [g.groupId],
        )).single['representative_id'],
        selected,
      );
      expect(first['member_count'], n - 1);
      expect(first['group_count'], 2);
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM duplicate_member'),
        ),
        n - 1,
      );
      final pages = events
          .where((e) => e['stage'] == 'duplicate.sql_page')
          .toList();
      expect(pages.every((e) => (e['rows'] as int) <= 128), isTrue);
      expect(
        pages.fold<int>(0, (s, e) => s + (e['rows'] as int)),
        greaterThanOrEqualTo(n),
      );
      final export = Platform.environment['SR_DUPLICATE_DB_OUT'];
      if (export != null) {
        await db.insert('sync_meta', {
          'key': 'kakao_member_id',
          'value': '910001',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        final watch = await db.rawQuery(
          "SELECT 신고번호 FROM reports WHERE 감시목록='Y' ORDER BY 신고번호",
        );
        for (final entry in {
          'watchlist': watch.map((r) => r['신고번호']).join(','),
          'last_sync': '2026-10-03T00:00:00',
          'fixture_null': null,
        }.entries) {
          await db.insert('sync_meta', {
            'key': entry.key,
            'value': entry.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await db.insert('report_override', {
          'ID': 'fixture-000000001',
          'column_name': '처리내용',
          'value': '교환 수정값\n보존',
          'updated_at': 1,
        });
        await db.insert('duplicate_decision', {
          'group_id': 'fixture-history',
          'status': 'not_duplicate',
          'representative_mode': 'manual',
          'representative_id': null,
          'apply_globally': 0,
          'note': null,
          'updated_at': 1,
        });
        await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
        await File(db.path).copy(export);
      }
      events.clear();
      final warmTimer = Stopwatch()..start();
      await DuplicateProjectionService.refreshDuplicateGroups(db);
      expect(events.where((e) => e['stage'] == 'duplicate.digest'), isEmpty);
      final warmMs = warmTimer.elapsedMilliseconds;
      await db.update(
        'reports',
        {'신고내용': '수정값', '처리상태': '일부수용'},
        where: 'ID=?',
        whereArgs: ['fixture-000000002'],
      );
      events.clear();
      await DuplicateProjectionService.refreshDuplicateGroups(db);
      expect(
        events
            .where((e) => e['stage'] == 'duplicate.digest')
            .fold<int>(0, (s, e) => s + (e['rows'] as int)),
        1,
      );
      await db.delete(
        'reports',
        where: 'ID=?',
        whereArgs: ['fixture-000000001'],
      );
      await DuplicateProjectionService.refreshDuplicateGroups(db);
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM duplicate_member'),
        ),
        n - 2,
      );
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_temp_master WHERE name LIKE 'sr_dup_%'",
        ),
        isEmpty,
      );
      // Host FFI correctness/diagnostics; no product/device latency claim.
      // ignore: avoid_print
      print(
        'SR_DUPLICATE_HOST rows=$n cold_ms=$coldMs warm_ms=$warmMs pages=${pages.length} rss=${ProcessInfo.currentRss} peak_rss=${ProcessInfo.maxRss}',
      );
      PerformanceTrace.observer = null;
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
