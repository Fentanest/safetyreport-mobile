import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/api_service.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/selfhost_client_fixture.dart';

http.Response config({bool supported = true}) => http.Response(
  jsonEncode({
    'data': {
      'capabilities': supported ? ['report_search_v1'] : [],
      'report_search_version': 1,
    },
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
http.Response searchPage(
  http.Request r, {
  String id = 'synthetic',
  int total = 401,
}) {
  final q = r.url.queryParameters;
  return http.Response(
    jsonEncode({
      'status': 'success',
      'search_version': 1,
      'filter': jsonDecode(q['filter']!),
      'category': r.url.path.split('/')[4],
      'offset': int.parse(q['offset']!),
      'limit': int.parse(q['limit']!),
      'dedupe_mode': q['dedupe'],
      'total': total,
      'data': [
        {
          'ID': id,
          '신고번호': 'SYN-$id',
          '신고명': id,
          'category': 'traffic',
          '신고내용': '합성 본문',
          '처리내용': '합성 처리',
          '첨부사진': 'synthetic.png',
          '보완_요청_내용': '보완',
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Widget list(ReportProvider p, String term) => ChangeNotifierProvider.value(
  value: p,
  child: MaterialApp(
    home: Scaffold(
      body: LocalPagedReportList(filter: ReportFilter(name: term)),
    ),
  ),
);
http.Response lawConfig({required bool lawSearch}) => http.Response(
  jsonEncode({
    'data': {
      'capabilities': [
        'report_search_v1',
        if (lawSearch) ServerContract.lawSearchCapability,
      ],
      'report_search_version': 1,
      if (lawSearch) 'law_search_version': ServerContract.lawSearchVersion,
    },
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUp(() {
    resetSelfhostFixture();
    SharedPreferences.setMockInitialValues({
      'appMode': 'server',
      'baseUrl': 'https://fixture.test',
      'apiKey': 'synthetic',
    });
  });
  testWidgets(
    'search uses only current + next full page; next and previous reuse cache',
    (tester) async {
      final p = ReportProvider();
      await p.init();
      addTearDown(p.dispose);
      final requests = <Uri>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(list(p, 'needle'));
          await tester.pumpAndSettle();
          expect(requests.map((u) => u.queryParameters['offset']), [
            '0',
            '200',
          ]);
          expect(requests.every((u) => u.path.endsWith('/all/search')), isTrue);
          expect(find.textContaining('전체 401건'), findsOneWidget);
          await tester.tap(find.byTooltip('다음 페이지'));
          await tester.pumpAndSettle();
          expect(requests.map((u) => u.queryParameters['offset']), [
            '0',
            '200',
            '400',
          ]);
          await tester.tap(find.byTooltip('이전 페이지'));
          await tester.pumpAndSettle();
          expect(requests, hasLength(3));
          await tester.pumpWidget(list(p, 'changed'));
          await tester.pumpAndSettle();
          expect(requests, hasLength(5));
          expect(
            jsonDecode(requests.last.queryParameters['filter']!)['name'],
            'changed',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => selfhostMockClient((r) async {
          if (r.url.path == ServerContract.appConfigPath) return config();
          requests.add(r.url);
          return searchPage(r);
        }),
      );
    },
  );
  testWidgets(
    'legacy server scans beyond first 200, counts exactly and is cancellable',
    (tester) async {
      final p = ReportProvider();
      await p.init();
      addTearDown(p.dispose);
      var pages = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(list(p, 'needle'));
          await tester.pumpAndSettle();
          expect(find.textContaining('전체 1건'), findsOneWidget);
          expect(find.text('needle'), findsOneWidget);
          expect(pages, 6); // 400 traffic + four empty categories
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => selfhostMockClient((r) async {
          if (r.url.path == ServerContract.appConfigPath) {
            return config(supported: false);
          }
          expect(r.url.path.endsWith('/page'), isTrue);
          pages++;
          final traffic = r.url.path.contains('/traffic/');
          final offset = int.parse(r.url.queryParameters['offset']!);
          return http.Response(
            jsonEncode({
              'total': traffic ? 400 : 0,
              'data': traffic
                  ? List.generate(
                      200,
                      (i) => {
                        'ID': '${offset + i}',
                        '신고번호': '${1000 - offset - i}',
                        '신고명': offset + i == 350 ? 'needle' : 'other',
                      },
                    )
                  : [],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
    },
  );
  test(
    'capability errors propagate; only successful absence allows legacy path',
    () async {
      for (final status in [401, 500, 404]) {
        final p = ReportProvider();
        await p.init();
        await http.runWithClient(() async {
          await expectLater(p.supportsServerSearch(), throwsException);
        }, () => selfhostMockClient((r) async => http.Response('{}', status)));
        p.dispose();
      }
    },
  );
  test(
    '200 ignoring search parameters is rejected; full detail and far offset preserved',
    () async {
      final api = ApiService(
        baseUrl: 'https://fixture.test',
        apiKey: 'synthetic',
      );
      await http.runWithClient(
        () async {
          await expectLater(
            api.getReportsPage(
              'all',
              searchFilter: const ReportFilter(name: 'x'),
            ),
            throwsFormatException,
          );
        },
        () => selfhostMockClient(
          (r) async => http.Response('{"data":[],"total":1}', 200),
        ),
      );
      await http.runWithClient(
        () async {
          final result = await api.getReportsPage(
            'all',
            offset: 10000,
            searchFilter: const ReportFilter(name: 'x'),
          );
          expect(result.reports.single.reportContent, '합성 본문');
          expect(result.reports.single.processContent, '합성 처리');
          expect(result.reports.single.attachedPhotos, 'synthetic.png');
          expect(result.reports.single.category, 'traffic');
          expect(result.reports.single.detailLoaded, isTrue);
        },
        () => selfhostMockClient((r) async {
          expect(r.url.queryParameters['offset'], '10000');
          return searchPage(r, total: 20000);
        }),
      );
    },
  );
  test(
    'search in-flight keys include filters and protect other consumers from cancellation',
    () async {
      final p = ReportProvider();
      await p.init();
      addTearDown(p.dispose);
      final ready = Completer<void>(), release = Completer<void>();
      var cancelled = false, requests = 0;
      await http.runWithClient(
        () async {
          final a = p.readServerSearchPage(
            'all',
            filter: const ReportFilter(name: 'a'),
            isCancelled: () => cancelled,
          );
          await ready.future;
          final b = p.readServerSearchPage(
            'all',
            filter: const ReportFilter(name: 'a'),
          );
          final c = p.readServerSearchPage(
            'all',
            filter: const ReportFilter(name: 'b'),
          );
          cancelled = true;
          release.complete();
          final results = await Future.wait([a, b, c]);
          expect(requests, 2);
          expect(results.map((p) => p.reports.single.id), ['a', 'a', 'b']);
        },
        () => selfhostMockClient((r) async {
          requests++;
          if (!ready.isCompleted) ready.complete();
          await release.future;
          return searchPage(
            r,
            id: jsonDecode(r.url.queryParameters['filter']!)['name'],
          );
        }),
      );
    },
  );
  testWidgets('late old search cannot replace a changed filter', (
    tester,
  ) async {
    final p = ReportProvider();
    await p.init();
    addTearDown(p.dispose);
    final release = Completer<void>();
    var started = false;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(list(p, 'old'));
        await tester.pump();
        for (var i = 0; i < 30 && !started; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(started, isTrue);
        await tester.pumpWidget(list(p, 'new'));
        await tester.pumpAndSettle();
        release.complete();
        await tester.pumpAndSettle();
        expect(find.text('new'), findsOneWidget);
        expect(find.text('old'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      () => selfhostMockClient((r) async {
        if (r.url.path == ServerContract.appConfigPath) return config();
        final term = jsonDecode(r.url.queryParameters['filter']!)['name'];
        if (term == 'old') {
          started = true;
          await release.future;
        }
        return searchPage(r, id: term, total: 1);
      }),
    );
  });
  test(
    'capability cancelled probe and epoch reset cannot cache stale support',
    () async {
      final p = ReportProvider();
      await p.init();
      addTearDown(p.dispose);
      var cancelled = true;
      await expectLater(
        p.supportsServerSearch(isCancelled: () => cancelled),
        throwsA(isA<QueryCancelled>()),
      );
      var calls = 0;
      await http.runWithClient(
        () async {
          expect(await p.supportsServerSearch(), isTrue);
          expect(await p.supportsServerSearch(), isTrue);
          expect(calls, 1);
          p.onGateBlocked();
          expect(await p.supportsServerSearch(), isFalse);
          expect(calls, 2);
        },
        () => selfhostMockClient((r) async {
          calls++;
          return config(supported: calls == 1);
        }),
      );
    },
  );
  test('timeout does not become unsupported capability', () async {
    final p = ReportProvider();
    await p.init();
    addTearDown(p.dispose);
    var calls = 0;
    await http.runWithClient(
      () async {
        await expectLater(
          p.supportsServerSearch(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'cause',
              contains('TimeoutException: synthetic'),
            ),
          ),
        );
        expect(calls, 5);
      },
      () => selfhostMockClient((r) async {
        calls++;
        throw TimeoutException('synthetic');
      }),
    );
  });
  test('last search consumer cancellation aborts the transport', () async {
    final p = ReportProvider();
    await p.init();
    addTearDown(p.dispose);
    var cancelled = false;
    final ready = Completer<void>(), release = Completer<void>();
    await http.runWithClient(
      () async {
        final result = p.readServerSearchPage(
          'all',
          filter: const ReportFilter(name: 'x'),
          isCancelled: () => cancelled,
        );
        final assertion = expectLater(result, throwsA(isA<QueryCancelled>()));
        await ready.future;
        cancelled = true;
        await assertion;
        release.complete();
      },
      () => selfhostMockClient((r) async {
        ready.complete();
        await release.future;
        return searchPage(r);
      }),
    );
  });

  // 2026-10-16: 법규 검색 v2 를 알린 서버에만 lawExact 를 보낸다. v3.3.0(신호 없음)은 모르는 키를 400 으로
  // 거절하고 법규를 저장값 완전 일치로 보므로 lawExact 를 빼고 원문 값을 그대로 보낸다.
  for (final lawSearch in [true, false]) {
    testWidgets(
      'law drilldown sends lawExact only to law_search_v2 ($lawSearch)',
      (tester) async {
        final p = ReportProvider();
        await p.init();
        addTearDown(p.dispose);
        final filters = <Map<String, dynamic>>[];
        const law = '도로교통법 제5조, 제6조';
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              ChangeNotifierProvider.value(
                value: p,
                child: const MaterialApp(
                  home: Scaffold(
                    body: LocalPagedReportList(
                      filter: ReportFilter(law: law, lawExact: true),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(filters, isNotEmpty);
            for (final f in filters) {
              expect(f['law'], law);
              expect(f.containsKey('lawExact'), lawSearch);
              if (lawSearch) expect(f['lawExact'], isTrue);
            }
            expect(p.lawKeySearchSupported, lawSearch);
            await tester.pumpWidget(const SizedBox.shrink());
          },
          () => selfhostMockClient((r) async {
            if (r.url.path == ServerContract.appConfigPath) {
              return lawConfig(lawSearch: lawSearch);
            }
            filters.add(
              Map<String, dynamic>.from(
                jsonDecode(r.url.queryParameters['filter']!) as Map,
              ),
            );
            return searchPage(r, total: 1);
          }),
        );
      },
    );
  }
  for (final identity in [true, false]) {
    testWidgets('identity keys require advertised capability ($identity)', (tester) async {
      final p = ReportProvider();
      await p.init();
      addTearDown(p.dispose);
      expect(p.reportSearchIdentitySupported, isFalse);
      final requests = <Uri>[];
      await http.runWithClient(() async {
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: LocalPagedReportList(
            category: 'all',
            filter: ReportFilter(agency: '합성기관', agencyKey: 'src:9999991:합성기관',
                manager: '김민수', managerExact: true),
          ))),
        ));
        await tester.pumpAndSettle();
        expect(p.reportSearchIdentitySupported, identity);
        final searches = requests.where((u) => u.path.endsWith('/search')).toList();
        expect(searches, hasLength(1));
        expect(searches.single.path, '/api/v1/reports/all/search');
        expect(requests.where((u) => u.path.endsWith('/page')), isEmpty);
        final f = jsonDecode(searches.single.queryParameters['filter']!) as Map;
        expect(f.containsKey('agencyKey'), identity);
        expect(f.containsKey('managerExact'), identity);
        expect(f['manager'], '김민수');
        if (identity) {
          expect(f['agencyKey'], 'src:9999991:합성기관');
          expect(f['managerExact'], isTrue);
          expect(f.containsKey('agency'), isFalse);
        } else {
          expect(f['agency'], '합성기관');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => selfhostMockClient((r) async {
        requests.add(r.url);
        if (r.url.path == ServerContract.appConfigPath) {
          return http.Response(jsonEncode({'data': {
            'capabilities': ['report_search_v1', if (identity) ServerContract.reportSearchIdentityCapability],
            'report_search_version': 1,
          }}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }
        return searchPage(r, total: 1);
      }));
    });
  }

}
