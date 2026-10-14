import 'dart:convert';
import 'package:safetyreport/models/report_filter.dart';
import 'package:safetyreport/services/law_values.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/services/api_service.dart';
import '../support/selfhost_client_fixture.dart';

void main() {
  setUp(resetSelfhostFixture);
  test(
    'Client sends individual second/third law and retains LF response',
    () async {
      const value = '도로교통법 제32조\n도로교통법 제33조\n도로교통법 제34조';
      for (final law in readLaws(value).skip(1)) {
        final filter = ReportFilter(law: law);
        await http.runWithClient(
          () async {
            final page = await ApiService(
              baseUrl: 'https://fixture.test',
              apiKey: 'fixture',
            ).getReportsPage('all', searchFilter: filter);
            expect(page.total, 1);
            expect(page.reports.single.law, value);
            expect(matchesLaws(page.reports.single.law, law), true);
          },
          () => selfhostMockClient((r) async {
            expect(r.url.path, '/api/v1/reports/all/search');
            expect(jsonDecode(r.url.queryParameters['filter']!)['law'], law);
            return http.Response(
              jsonEncode({
                'status': 'success',
                'search_version': 1,
                'category': 'all',
                'offset': 0,
                'limit': 200,
                'dedupe_mode': 'canonical',
                'filter': filter.toSearchJson(),
                'total': 1,
                'data': [
                  {'ID': 'fixture', '위반법규': value, 'category': 'traffic'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
      }
    },
  );
  test(
    'page uses canonical route, exact total, NULL and category with no full-report fallback',
    () async {
      final requests = <String>[];
      await http.runWithClient(
        () async {
          final page = await ApiService(
            baseUrl: 'https://fixture.test',
            apiKey: 'fixture',
          ).getReportsPage('traffic', offset: 200, limit: 200, dedupe: 'raw');
          expect(page.total, 500000);
          expect(page.reports.single.id, 'fixture');
          expect(page.reports.single.agencyCode, isNull);
          expect(page.reports.single.category, 'traffic');
        },
        () => selfhostMockClient((r) async {
          requests.add(r.url.path);
          expect(r.url.queryParameters, {
            'offset': '200',
            'limit': '200',
            'dedupe': 'raw',
          });
          expect(r.headers['X-SafetyReport-Protocol'], '3');
          return http.Response(
            jsonEncode({
              'status': 'success',
              'total': 500000,
              'offset': 200,
              'limit': 200,
              'data': [
                {'ID': 'fixture', '처리기관코드': null},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      expect(requests, ['/api/v1/reports/traffic/page']);
    },
  );
  test('bounded map carries viewport and raw/canonical mode', () async {
    await http.runWithClient(
      () async {
        final payload =
            await ApiService(
              baseUrl: 'https://fixture.test',
              apiKey: 'fixture',
            ).getReportMapStats(
              year: '2026',
              bounds: [33, 124, 39, 132],
              zoom: 12,
              dedupe: 'raw',
            );
        expect(payload.meta.totalReports, 500000);
        expect(payload.points, isEmpty);
      },
      () => selfhostMockClient((r) async {
        expect(r.url.path, '/api/v1/stats/map/points');
        expect(r.url.queryParameters, {
          'year': '2026',
          'bounds': '33.0,124.0,39.0,132.0',
          'zoom': '12',
          'max_points': '1024',
          'dedupe': 'raw',
        });
        return http.Response(
          '{"status":"success","data":{"points":[],"meta":{"total_reports":500000}}}',
          200,
        );
      }),
    );
  });
  test(
    'missing page/map API asks for PC update without requesting unlimited endpoint',
    () async {
      final requests = <String>[];
      await http.runWithClient(
        () async {
          final api = ApiService(
            baseUrl: 'https://fixture.test',
            apiKey: 'fixture',
          );
          await expectLater(
            api.getReportsPage('traffic'),
            throwsA(isA<ApiFeatureUnavailableException>()),
          );
          await expectLater(
            api.getReportMapStats(),
            throwsA(isA<ApiFeatureUnavailableException>()),
          );
        },
        () => selfhostMockClient((r) async {
          requests.add(r.url.path);
          return http.Response('', 404);
        }),
      );
      expect(requests, [
        '/api/v1/reports/traffic/page',
        '/api/v1/stats/map/points',
      ]);
    },
  );
  test(
    'filter laws use the compact overview rather than downloading reports',
    () async {
      final paths = <String>[];
      await http.runWithClient(
        () async {
          final options = await ApiService(
            baseUrl: 'https://fixture.test',
            apiKey: 'fixture',
          ).getFilterOptions();
          expect(options.laws, ['도로교통법', '__없음__']);
          expect(options.statuses, containsAll(['일부수용', '답변완료', '취하']));
        },
        () => selfhostMockClient((r) async {
          paths.add(r.url.path);
          expect(r.headers['X-SafetyReport-Protocol'], '3');
          return http.Response(
            jsonEncode({
              'status': 'success',
              'data': {
                'all': {
                  'violation_laws': [
                    {'name': '도로교통법', 'filter': '도로교통법', 'count': 499999},
                    {'name': '', 'filter': '__없음__', 'count': 1},
                  ],
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      expect(paths, ['/api/v1/stats/overview']);
    },
  );

  test(
    'getReportsPage allows all 5 categories, rejects unknown ones',
    () async {
      final api = ApiService(
        baseUrl: 'https://fixture.test',
        apiKey: 'fixture',
      );
      for (final category in const [
        'traffic',
        'parking',
        'safety',
        'living',
        'other',
      ]) {
        final requests = <String>[];
        await http.runWithClient(
          () async {
            final page = await api.getReportsPage(category);
            expect(page.total, 0);
          },
          () => selfhostMockClient((r) async {
            requests.add(r.url.path);
            return http.Response(
              jsonEncode({
                'status': 'success',
                'total': 0,
                'offset': 0,
                'limit': 200,
                'data': [],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
        expect(requests, ['/api/v1/reports/$category/page']);
      }
      await expectLater(api.getReportsPage('bogus'), throwsArgumentError);
    },
  );
}
