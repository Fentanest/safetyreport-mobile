import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/standalone_api_service.dart';
import 'package:safetyreport/services/sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late CommunityStore store;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('sr_inventory_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
    store = await CommunityStore.open(
      path: '${dir.path}/community.db',
      factory: databaseFactoryFfi,
    );
    SyncEngine.openCommunityStoreForTest = () async => store;
    SyncEngine.retryFileForTest = File('${dir.path}/retry.json');
    SyncEngine.backfillForTest = () async => 0;
    StandaloneApiService.detailForTest = (_) async =>
        throw const SocketException('synthetic offline');
    final db = await LocalDbService.db;
    await db.insert('reports', {
      'ID': '001',
      '신고번호': 'SPP-synthetic',
      'category': 'traffic',
    });
    await db.insert('report_raw', {
      'ID': '001',
      'raw_content': '합성\n원문',
      'raw_type': 'json',
      'saved_at': 1,
    });
    await db.insert('report_override', {
      'ID': '001',
      'column_name': '신고명',
      'value': '',
      'updated_at': 1,
    });
  });
  tearDown(() async {
    StandaloneApiService.listForTest = null;
    StandaloneApiService.detailForTest = null;
    SyncEngine.openCommunityStoreForTest = null;
    SyncEngine.retryFileForTest = null;
    SyncEngine.backfillForTest = null;
    await LocalDbService.closeDb();
    await CommunityStore.closeForTest(store.path);
    await dir.delete(recursive: true);
  });
  test(
    'duplicate source ID across pages fails inventory before any detail request',
    () async {
      var calls = 0;
      StandaloneApiService.listForTest = (start, end) async => {
        'totalCnt': 401,
        'result': end == 1
            ? [
                {'C_NO': 'id-0'},
              ]
            : List.generate(
                end - start + 1,
                (i) => {
                  'C_NO': start == 201 && i == 0
                      ? 'id-0'
                      : 'id-${start + i - 1}',
                },
              ),
      };
      StandaloneApiService.detailForTest = (_) async {
        calls++;
        throw StateError('must not fetch');
      };
      final result = await SyncEngine.start(fullSync: true);
      expect(result.failed, isTrue);
      expect(result.listComplete, isFalse);
      expect(calls, 0);
      final db = await LocalDbService.db;
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_temp_master WHERE name LIKE 'sr_sync_%'",
        ),
        isEmpty,
      );
    },
  );

  test(
    'stop during rebuild preflight remains cancelled and concurrent start is busy',
    () async {
      final entered = Completer<void>();
      final released = Completer<void>();
      SyncEngine.rebuildBlocks = () async {
        entered.complete();
        await released.future;
        return false;
      };
      addTearDown(() {
        SyncEngine.rebuildBlocks = null;
      });
      var calls = 0;
      StandaloneApiService.listForTest = (_, _) async {
        calls++;
        return {'totalCnt': 0, 'result': []};
      };
      final first = SyncEngine.start();
      await entered.future;
      expect((await SyncEngine.start()).busy, isTrue);
      SyncEngine.stop();
      released.complete();
      expect((await first).cancelled, isTrue);
      expect(calls, 0);
    },
  );
  for (final result in [
    null,
    <dynamic>[],
    [
      {'C_NO': '002'},
    ],
    [
      {'C_NO': '002'},
      {'C_NO': '002'},
      {'C_NO': '003'},
    ],
  ]) {
    test(
      'full sync preserves absent report/raw/override for malformed or incomplete HTTP 200: $result',
      () async {
        StandaloneApiService.listForTest = (start, end) async => {
          'totalCnt': 3,
          'result': end == 1
              ? [
                  {'C_NO': '002'},
                ]
              : result,
        };
        await SyncEngine.start(fullSync: true);
        final db = await LocalDbService.db;
        expect(
          (await db.query(
            'reports',
            where: 'ID=?',
            whereArgs: ['001'],
          )).single['ID'],
          '001',
        );
        expect((await db.query('report_raw')).single['raw_content'], '합성\n원문');
        expect((await db.query('report_override')).single['value'], '');
      },
    );
  }
  test('matching total does not authorize absence deletion', () async {
    StandaloneApiService.listForTest = (_, _) async => {
      'totalCnt': 1,
      'result': [
        {'C_NO': '002'},
      ],
    };
    await SyncEngine.start(fullSync: true);
    expect(
      (await (await LocalDbService.db).query('reports')).single['ID'],
      '001',
    );
  });
  test(
    'HTTP 200 missing total never becomes a successful empty inventory',
    () async {
      StandaloneApiService.listForTest = (_, _) async => {'result': null};
      final result = await SyncEngine.start(fullSync: true);
      expect(result.failed, isTrue);
    },
  );
}
