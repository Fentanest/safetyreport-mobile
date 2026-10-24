// 공식 목록 API 제한(2026-10-24 실측): 조회 기간 최대 1년(list_date_range_too_large), 한 번에 최대 50건
// (list_page_size_too_large). 가짜 공식 서버가 같은 제한을 강제하고, 연도 구간을 이어 붙인 결과가
// 예전 한 번 조회와 같은지(누락·중복 없음, 최신순, 건수 변경 감지) 확인한다. 합성 데이터만 쓴다.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/official_session.dart';
import 'package:safetyreport/services/standalone_api_service.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/services/sync_inventory.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSite {
  _FakeSite(this.rows);

  /// (C_NO, C_DATE). 사이트는 최신순으로 돌려준다.
  final List<({String id, String date})> rows;
  final requests = <Uri>[];

  http.Response handle(http.Request req) {
    requests.add(req.url);
    final q = req.url.queryParameters;
    final from = DateTime.parse(q['C_FRM_DATE']!);
    final to = DateTime.parse(q['C_TO_DATE']!);
    final a = int.parse(q['startRowNum']!), b = int.parse(q['endRowNum']!);
    String limited(String reason) =>
        jsonEncode({'error': 'request_limited', 'reason': reason});
    if (to.difference(from).inDays > 365) {
      return http.Response(limited('list_date_range_too_large'), 400);
    }
    if (b - a + 1 > 50) {
      return http.Response(limited('list_page_size_too_large'), 400);
    }
    final inRange =
        rows.where((r) {
          final d = r.date.substring(0, 10);
          return d.compareTo(q['C_FRM_DATE']!) >= 0 &&
              d.compareTo(q['C_TO_DATE']!) <= 0;
        }).toList()..sort((x, y) {
          final n = y.date.compareTo(x.date);
          return n != 0 ? n : y.id.compareTo(x.id);
        });
    final page = inRange.skip(a - 1).take(b - a + 1);
    return http.Response(
      jsonEncode({
        'result': [
          for (final r in page) {'C_NO': r.id, 'C_DATE': r.date},
        ],
        'totalCnt': inRange.length,
      }),
      200,
      headers: {'content-type': 'application/json;charset=UTF-8'},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    StandaloneAuthService.invalidateOperations();
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.standaloneUsername: 'tester',
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.secureStorageV10Migrated: true,
    });
    FlutterSecureStorage.setMockInitialValues({
      StandaloneAuthService.sessionStorageKey: OfficialSession(
        token: 'synthetic-token',
        username: 'tester',
        epoch: '',
        expiresAt: DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        cookies: const {'JSESSIONID': 'synthetic-session'},
      ).encode(),
    });
  });
  tearDown(() => StandaloneApiService.httpClientFactoryForTest = null);

  test(
    'yearly windows: newest first, each within one year, contiguous from 2014',
    () {
      for (final today in [
        DateTime(2026, 10, 24),
        DateTime(2024, 12, 31),
        DateTime(2028, 2, 29),
        DateTime(2026, 1, 1),
      ]) {
        final windows = StandaloneApiService.listWindows(today);
        expect(windows.first.to, today.toIso8601String().substring(0, 10));
        expect(windows.last.from, '2014-01-01');
        for (var i = 0; i < windows.length; i++) {
          final from = DateTime.parse(windows[i].from);
          final to = DateTime.parse(windows[i].to);
          expect(to.difference(from).inDays, inInclusiveRange(0, 365));
          if (i > 0) {
            // 앞(더 최신) 구간 시작일 바로 전날이 이 구간의 끝이다 — 빈 날짜도 겹치는 날짜도 없다.
            expect(
              DateTime.parse(windows[i - 1].from).difference(to).inDays,
              1,
            );
          }
        }
      }
    },
  );

  test(
    'stitched pages equal one full newest-first list across year boundaries',
    () async {
      final now = DateTime.now();
      final rows = <({String id, String date})>[];
      // 경계일(12-31·01-01)·올해 오늘을 포함해 여러 해에 걸친 합성 신고 437건.
      var n = 0;
      for (var y = now.year; y >= now.year - 4; y--) {
        for (final md in ['01-01', '03-15', '06-30', '12-31']) {
          final date = '$y-$md';
          if (DateTime.parse(date).isAfter(now)) continue;
          for (var k = 0; k < 27; k++) {
            rows.add((
              id: 'R${(n++).toString().padLeft(4, '0')}',
              date: '$date 1$k:00'.substring(0, 16),
            ));
          }
        }
      }
      rows.add((id: 'R9999', date: now.toIso8601String().substring(0, 10)));
      final site = _FakeSite(rows);
      StandaloneApiService.httpClientFactoryForTest = () =>
          MockClient((req) async => site.handle(req));

      final total = await StandaloneApiService.fetchTotalCount();
      expect(total, rows.length);
      final inventory = ListInventory(total);
      final ids = <String>[];
      for (var start = 1; start <= total; start += 200) {
        final end = (start + 199).clamp(1, total);
        final page = inventory.addPage(
          await StandaloneApiService.fetchReportList(
            startRow: start,
            endRow: end,
          ),
          start,
          end,
        );
        ids.addAll(page.map((r) => r['C_NO'].toString()));
      }
      expect(ids.toSet(), rows.map((r) => r.id).toSet());
      expect(ids.length, rows.length);
      final expected = [...rows]
        ..sort((x, y) {
          final c = y.date.compareTo(x.date);
          return c != 0 ? c : y.id.compareTo(x.id);
        });
      expect(ids, expected.map((r) => r.id).toList());
      // 모든 요청이 제한 안이었다(제한을 넘으면 가짜 사이트가 400 을 돌려 위에서 실패한다).
      expect(site.requests, isNotEmpty);
    },
  );

  test(
    'a report added while paging changes totalCnt so the list check re-reads',
    () async {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final rows = [
        for (var i = 0; i < 120; i++)
          (id: 'A${i.toString().padLeft(3, '0')}', date: today),
      ];
      final site = _FakeSite(rows);
      StandaloneApiService.httpClientFactoryForTest = () =>
          MockClient((req) async => site.handle(req));
      final total = await StandaloneApiService.fetchTotalCount();
      final inventory = ListInventory(total);
      rows.add((id: 'A999', date: today));
      final data = await StandaloneApiService.fetchReportList(
        startRow: 1,
        endRow: 100,
      );
      expect(data['totalCnt'], 121);
      expect(() => inventory.addPage(data, 1, 100), throwsFormatException);
    },
  );

  test('official rejection keeps the HTTP status and reason code only', () async {
    StandaloneApiService.httpClientFactoryForTest = () => MockClient(
      (req) async => http.Response(
        '{"error":"request_limited","reason":"list_page_size_too_large","secret":"x"}',
        400,
      ),
    );
    await expectLater(
      StandaloneApiService.fetchTotalCount(),
      throwsA(
        predicate(
          (e) =>
              '$e'.contains('목록 조회 실패 (400) list_page_size_too_large') &&
              !'$e'.contains('secret'),
        ),
      ),
    );
  });

  test(
    'report number year: YYMM prefix, neighbour year at Dec/Jan, else null',
    () {
      expect(StandaloneApiService.reportNumberYears('SPP-2610-0123456'), {
        2026,
      });
      expect(StandaloneApiService.reportNumberYears('2406-1'), {2024});
      expect(StandaloneApiService.reportNumberYears('spp-2512-7'), {
        2025,
        2026,
      });
      expect(StandaloneApiService.reportNumberYears('SPP-2501-7'), {
        2025,
        2024,
      });
      for (final bad in ['SPP-2613-1', 'SPP-26-1', '123', '', 'SPP-2610']) {
        expect(
          StandaloneApiService.reportNumberYears(bad),
          isNull,
          reason: bad,
        );
      }
    },
  );

  test('year-scoped list asks only that year window', () async {
    final now = DateTime.now();
    final last = now.year - 1;
    final rows = [
      (id: 'Y1', date: '$last-05-01'),
      (id: 'Y2', date: '$last-12-31'),
      (id: 'N1', date: now.toIso8601String().substring(0, 10)),
    ];
    final site = _FakeSite(rows);
    StandaloneApiService.httpClientFactoryForTest = () =>
        MockClient((req) async => site.handle(req));
    final years = {last};
    expect(await StandaloneApiService.fetchTotalCount(years: years), 2);
    final data = await StandaloneApiService.fetchReportList(
      startRow: 1,
      endRow: 2,
      years: years,
    );
    expect((data['result'] as List).map((r) => r['C_NO']), ['Y2', 'Y1']);
    expect(site.requests.map((u) => u.queryParameters['C_FRM_DATE']).toSet(), {
      '$last-01-01',
    });
  });
}
