// WP8 Provider 회귀:
// SQ-B11 로딩 표시는 겹친 조회가 모두 끝나야 꺼진다.
// SQ-B10 감시 목록 변경은 요청 중 자료셋이 바뀌면 새 자료셋에 쓰지 않고, 같은 Set 을 제자리에서 바꾸지 않는다.
// SQ-P07 값이 그대로인 조회 결과는 알리지 않는다.
// SQ-P02 Standalone refreshAll 은 DB 에 쓰기가 없으면 dataRevision 을 올리지 않는다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../tool/large_data_fixture.dart';
import '../support/selfhost_client_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

  setUp(() {
    resetSelfhostFixture();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(perm, (_) async => true);
    BackgroundLoginCheck.schedulingEnabled = false;
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(perm, null);
    BackgroundLoginCheck.schedulingEnabled = true;
  });

  Future<ReportProvider> clientProvider() async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'https://a.test',
      AppPrefsKeys.apiKey: 'synthetic',
    });
    final provider = ReportProvider();
    addTearDown(provider.dispose);
    await provider.init();
    return provider;
  }

  test(
    'SQ-B11 overlapping loads keep isLoading until the last one ends',
    () async {
      final provider = await clientProvider();
      final summary = Completer<void>();
      final duplicates = Completer<void>();
      await http.runWithClient(
        () async {
          final a = provider.fetchSummary();
          final b = provider.fetchDuplicateReports();
          await Future<void>.delayed(Duration.zero);
          expect(provider.isLoading, isTrue);

          summary.complete();
          await a;
          expect(provider.isLoading, isTrue, reason: '중복 조회가 아직 돈다');

          duplicates.complete();
          await b;
          expect(provider.isLoading, isFalse);
        },
        () => selfhostMockClient((request) async {
          final path = request.url.path;
          if (path == ServerContract.summaryPath) {
            await summary.future;
            return http.Response(
              jsonEncode({
                'data': {'total': 1},
              }),
              200,
            );
          }
          await duplicates.future;
          return http.Response(jsonEncode({'data': []}), 200);
        }),
      );
    },
  );

  test(
    'SQ-B11 a load abandoned by a dataset switch does not leave the spinner on',
    () async {
      final provider = await clientProvider();
      final reply = Completer<void>();
      await http.runWithClient(
        () async {
          final pending = provider.fetchDuplicateReports();
          await Future<void>.delayed(Duration.zero);
          expect(provider.isLoading, isTrue);
          await provider.setConfig('https://b.test', 'synthetic');
          reply.complete();
          await pending;
          expect(provider.isLoading, isFalse);
        },
        () => selfhostMockClient((request) async {
          await reply.future;
          return http.Response(jsonEncode({'data': []}), 200);
        }),
      );
    },
  );

  test(
    'SQ-B10 watchlist add replaces the Set and ignores results after a dataset switch',
    () async {
      final provider = await clientProvider();
      final reply = Completer<void>();
      var holdReply = false;
      await http.runWithClient(
        () async {
          final before = provider.watchlistNumbers;
          await provider.addToWatchlist(['SPP-1']);
          expect(provider.watchlistNumbers, {'SPP-1'});
          expect(
            identical(provider.watchlistNumbers, before),
            isFalse,
            reason: '새 Set 을 넣어야 이전 값과 비교하는 화면이 변경을 안다',
          );

          final afterAdd = provider.watchlistNumbers;
          await provider.removeFromWatchlist(['SPP-1']);
          expect(provider.watchlistNumbers, isEmpty);
          expect(afterAdd, {'SPP-1'}, reason: '이전 Set 을 제자리에서 바꾸지 않는다');

          holdReply = true;
          final pending = provider.addToWatchlist(['SPP-2']);
          await Future<void>.delayed(Duration.zero);
          await provider.setConfig('https://b.test', 'synthetic');
          reply.complete();
          await pending;
          expect(
            provider.watchlistNumbers,
            isEmpty,
            reason: '이전 서버의 결과를 새 서버 자료에 쓰지 않는다',
          );
        },
        () => selfhostMockClient((request) async {
          if (holdReply) await reply.future;
          return http.Response(jsonEncode({'success': true}), 200);
        }),
      );
    },
  );

  test(
    'SQ-P07 unchanged watchlist and app config results do not notify',
    () async {
      final provider = await clientProvider();
      var notifications = 0;
      provider.addListener(() => notifications++);
      Future<void> run(Future<void> Function() body) => http.runWithClient(
        body,
        () => selfhostMockClient((request) async {
          final path = request.url.path;
          if (path == ServerContract.watchlistPath) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'신고번호': 'SPP-1'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'data': {
                'exclude_withdraw': true,
                'use_representative_records': true,
                'capabilities': ['rating_cause'],
              },
            }),
            200,
          );
        }),
      );

      await run(provider.fetchWatchlistNumbers);
      await run(provider.fetchAppConfig);
      expect(notifications, 2);
      await run(provider.fetchWatchlistNumbers);
      await run(provider.fetchAppConfig);
      expect(notifications, 2, reason: '같은 값이면 알리지 않는다');
      provider.setFilter(const ReportFilter());
      expect(notifications, 2);
    },
  );

  test(
    'SQ-P02 standalone refreshAll bumps dataRevision only after a write',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = Directory.systemTemp.createTempSync('sr_revision_');
      await databaseFactory.setDatabasesPath(dir.path);
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'standalone',
        AppPrefsKeys.standaloneUsername: 'fixture',
        AppPrefsKeys.standalonePhoneNumber: 'fixture',
      });
      final provider = ReportProvider();
      addTearDown(() async {
        provider.dispose();
        await LocalDbService.closeDb();
        dir.deleteSync(recursive: true);
      });
      final db = await LocalDbService.db;
      await seedLargeDataFixture(db, 30);
      await provider.init();

      await provider.refreshAll();
      final first = provider.dataRevision;
      expect(first, greaterThan(0), reason: '처음 본 DB 상태는 변경으로 본다');
      // 백그라운드 사진 훑기가 끝날 시간을 준다(대상이 없으면 쓰지 않는다).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await provider.refreshAll();
      final settled = provider.dataRevision;
      await provider.refreshAll();
      await provider.refreshAll();
      expect(provider.dataRevision, settled, reason: '쓰기가 없으면 다시 읽으라고 알리지 않는다');

      await db.update(
        'reports',
        {'처리상태': '수용'},
        where: 'ID=?',
        whereArgs: ['fixture-000000001'],
      );
      await provider.refreshAll();
      expect(provider.dataRevision, settled + 1);
      await provider.refreshAll();
      expect(provider.dataRevision, settled + 1);
    },
  );
}
