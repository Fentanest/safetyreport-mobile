// rebuild 분류·staging 병합·rotate 훅·빌드 스크립트 테스트 (네트워크 없음).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/capture/rebuild_helpers.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/sync_engine.dart';

Future<CommunityStore> openStore(Directory dir) async {
  sqfliteFfiInit();
  final store = await CommunityStore.open(
      path: '${dir.path}/community.db', factory: databaseFactoryFfi);
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

Map<String, Object?> adapter(String status) => {
      'processing_status': status,
      'penalty_amount': status == '수용' ? '과태료: 40,000원' : '',
      'report_date': '2026-09-01',
      'response_date': status == '수용' ? '2026-09-10' : '',
      'processing_agency': '서울특별시 중구청',
      'person_in_charge': '홍길동',
      'car_number': '12가3456',
      'violation_location': '서울특별시 중구 세종대로 110',
      'entry_value': '불법주정차신고',
      'penalty_points': '',
      'geocode': {'status': 'pending'},
      'progress_status': status,
    };

void main() {
  group('rebuild helpers', () {
    test('상세 오류 분류', () {
      expect(classifyDetailError(Exception('네트워크 오류 errno=104')),
          equals('failed_retryable'));
      expect(classifyDetailError(Exception('HTTP 503')), equals('failed_retryable'));
      expect(classifyDetailError(Exception('삭제된 신고입니다')),
          equals('failed_permanent'));
      expect(classifyDetailError(Exception('접근 거부')), equals('failed_permanent'));
    });

    test('5회 초과면 permanent 승격', () {
      expect(nextItemStateAfterFailure(1), equals('failed_retryable'));
      expect(nextItemStateAfterFailure(4), equals('failed_retryable'));
      expect(nextItemStateAfterFailure(5), equals('failed_permanent'));
    });

    test('registerRebuildItems: pending 등록·fetched 유지(재개)', () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('sr_t6_rb_');
      final store = await openStore(dir);
      try {
        await SyncEngine.registerRebuildItems(store, 'run1', {'a', 'b'});
        await store.db.rawUpdate(
            "UPDATE rebuild_items SET state='fetched' WHERE run_id='run1' AND source_report_id='a'");
        await SyncEngine.registerRebuildItems(
            store, 'run1', {'a', 'b', 'c'});
        final rows = await store.db.rawQuery(
            'SELECT source_report_id AS id, state FROM rebuild_items WHERE run_id=? ORDER BY id',
            ['run1']);
        expect(rows.map((r) => '${r['id']}:${r['state']}').toList(),
            equals(['a:fetched', 'b:pending', 'c:pending']));
      } finally {
        final path = store.path;
        await store.db.close();
        await CommunityStore.closeForTest(path);
        await dir.delete(recursive: true);
      }
    });

    test('mergeRebuildStaging: 병합만, 없는 행은 carry-forward', () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('sr_t6_merge_');
      final store = await openStore(dir);
      try {
        // 기존 완료 행 R0.
        await capture(adapter('수용'),
            sourceReportId: 'R0', trigger: 'realtime',
            store: store, projectNamespace: 'ns1');
        // rebuild run: R1 신규 + R0 무변경 포인터 carry.
        await capture(adapter('수용'),
            sourceReportId: 'R1', trigger: 'rebuild', rebuildRunId: 'run1',
            store: store, projectNamespace: 'ns1');
        await capture(adapter('수용'),
            sourceReportId: 'R0', trigger: 'rebuild', rebuildRunId: 'run1',
            store: store, projectNamespace: 'ns1');
        final merged = await mergeRebuildStaging('run1', store: store);
        expect(merged, equals(2));
        final latest = await store.db.rawQuery(
            'SELECT source_report_id AS id FROM report_latest ORDER BY id');
        expect(latest.map((r) => r['id']).toList(), equals(['R0', 'R1']));
        // 영구 실패 R2 는 staging 에 없어 기존 행 그대로 (여기서는 없음).
        final r2 = await store.db.rawQuery(
            "SELECT * FROM report_latest WHERE source_report_id='R2'");
        expect(r2, isEmpty);
      } finally {
        final path = store.path;
        await store.db.close();
        await CommunityStore.closeForTest(path);
        await dir.delete(recursive: true);
      }
    });
  });

  group('rotate hook', () {
    test('replaceFromBackup 전에 rotateDataset(restore) 호출', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('sr_t6_rot_');
      final prevPath = await databaseFactory.getDatabasesPath();
      await databaseFactory.setDatabasesPath(dir.path);
      SharedPreferences.setMockInitialValues({});
      try {
        // 현재 DB: 최소 reports 한 건 (마이그레이션으로 생성).
        final db = await LocalDbService.db;
        final version = await db.getVersion();
        await db.insert('reports', {
          'ID': 'live1',
          '신고번호': 'SPP-live1',
          'category': 'parking',
        });
        await LocalDbService.closeDb();
        // 백업 파일: exportBackup 으로 만든 진짜 백업 (형식 보장).
        final backupPath = '${dir.path}/backup.db';
        await LocalDbService.exportBackup(backupPath);
        // community dataset id 기록.
        final before = await CommunityStore.open();
        final beforeId = await before.localDatasetId();
        await CommunityStore.closeForTest(before.path);

        await LocalDbService.replaceFromBackup(backupPath);

        final after = await CommunityStore.open();
        final afterId = await after.localDatasetId();
        expect(afterId, isNot(equals(beforeId)));
        final history = await after.meta('dataset_history');
        expect(history, contains('restore'));
        await CommunityStore.closeForTest(after.path);
        expect(version, greaterThanOrEqualTo(1));
      } finally {
        await LocalDbService.closeDb();
        await databaseFactory.setDatabasesPath(prevPath);
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('build config', () {
    test('release 자리표시자·비밀 거부, debug 무값 허용', () async {
      Future<int> run(Map<String, String> env, String mode) async {
        final res = await Process.run(
          'bash',
          [
            '-c',
            'source build_android_common.sh && prepare_community_public_config "\$PWD" $mode',
          ],
          workingDirectory: Directory.current.path,
          environment: env,
        );
        return res.exitCode;
      }

      final base = Map<String, String>.from(Platform.environment)
        ..remove('COMMUNITY_SUPABASE_URL')
        ..remove('COMMUNITY_SUPABASE_PUBLISHABLE_KEY');
      expect(await run(base, 'debug'), equals(0));
      expect(await run(base, 'release'), isNot(equals(0)));
      expect(
          await run(
              {
                ...base,
                'COMMUNITY_SUPABASE_URL': 'https://<PROJECT_REF>.supabase.co',
                'COMMUNITY_SUPABASE_PUBLISHABLE_KEY': 'sb_publishable_x',
              },
              'release'),
          isNot(equals(0)));
      expect(
          await run(
              {
                ...base,
                'COMMUNITY_SUPABASE_URL': 'https://abc.supabase.co',
                'COMMUNITY_SUPABASE_PUBLISHABLE_KEY': 'sb_secret_x',
              },
              'release'),
          isNot(equals(0)));
      expect(
          await run(
              {
                ...base,
                'COMMUNITY_SUPABASE_URL': 'https://abc.supabase.co',
                'COMMUNITY_SUPABASE_PUBLISHABLE_KEY':
                    'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.c2ln',
              },
              'release'),
          equals(0));
      try {
        await File('build/community_public.json').delete();
      } catch (_) {}
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
