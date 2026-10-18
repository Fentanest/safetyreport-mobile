import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/statistics_screen.dart';
import 'package:safetyreport/screens/filtered_list_screen.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/selfhost_client_fixture.dart';

class _Client extends ReportProvider {
  @override
  AppMode get appMode => AppMode.server;
  @override
  String get baseUrl => 'https://fixture.test';
  @override
  String get apiKey => 'synthetic';
  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (reports: <Report>[], total: 0);
}

void main() {
  for (final hasAll in [true, false]) {
    testWidgets('전체 칩 기본 선택/구서버 폴백: all=$hasAll', (tester) async {
      resetSelfhostFixture();
      SharedPreferences.setMockInitialValues({});
      final provider = _Client();
      addTearDown(provider.dispose);
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final category = <String, dynamic>{
        'by_agency': [
          {'agency': '합성 공통기관', 'agency_key': 'src:-:합성 공통기관', 'total': 2},
        ],
        'by_person': [], 'available_laws': ['주정차 전용법'],
      };
      var statsRequests = 0;
      await http.runWithClient(() async {
        await tester.pumpWidget(ChangeNotifierProvider<ReportProvider>.value(
          value: provider,
          child: MaterialApp(theme: AppTheme.light(), home: const StatisticsScreen()),
        ));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(statsRequests, greaterThan(0));
        final all = find.byKey(const ValueKey('stats-category-all'));
        final traffic = find.byKey(const ValueKey('stats-category-traffic'));
        bool selected(Finder chip) => tester.widget<Semantics>(
          find.descendant(of: chip, matching: find.byType(Semantics)).first,
        ).properties.selected!;
        if (hasAll) {
          expect(all, findsOneWidget);
          expect(selected(all), isTrue);
          expect(selected(traffic), isFalse);
          await tester.tap(traffic);
          await tester.pump(const Duration(milliseconds: 200));
          expect(selected(traffic), isTrue);
          await tester.tap(all);
          await tester.pump(const Duration(milliseconds: 200));
          expect(selected(all), isTrue);
          await tester.tap(find.byKey(const ValueKey('stats-law-picker')));
          await tester.pumpAndSettle();
          expect(find.text('주정차 전용법'), findsOneWidget);
          Navigator.of(tester.element(find.text('위반법규 선택'))).pop();
          await tester.pumpAndSettle();
          final card = find.text('합성 공통기관');
          final list = find.descendant(
            of: find.byKey(const PageStorageKey('stats-list')),
            matching: find.byType(Scrollable),
          ).first;
          await tester.scrollUntilVisible(card, 300, scrollable: list);
          await tester.tap(card);
          await tester.pumpAndSettle();
          final screen = tester.widget<FilteredListScreen>(find.byType(FilteredListScreen));
          expect(screen.category, 'all');
          expect(screen.reportFilter.agency, '합성 공통기관');
          expect(screen.reportFilter.statuses, contains('수용'));
          expect(screen.reportFilter.statuses, isNot(contains('처리중')));
          // 조회 뒤 Dart 로 거르지 않는다: 페이지 나눔·건수·서버 검색이 조회 조건 그대로(Astra 교차 확인).
          expect(screen.filter, isNull);
          expect(provider.filter, const ReportFilter());
        } else {
          expect(all, findsNothing);
          expect(selected(traffic), isTrue);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      }, () => selfhostMockClient((request) async {
        if (request.url.path == ServerContract.statsPath) {
          statsRequests++;
          return http.Response(jsonEncode({'data': {
            for (final cat in ['traffic', 'parking', 'safety', 'living', 'other']) cat: category,
            if (hasAll) 'all': category,
          }}), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }
        if (request.url.path == ServerContract.statsOverviewPath) {
          return http.Response(jsonEncode({'data': {
            'all': {'total': 10}, 'traffic': {'total': 4},
          }}), 200);
        }
        return http.Response('{}', 404);
      }));
    });
  }
}
