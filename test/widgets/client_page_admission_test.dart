import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:safetyreport/widgets/local_paged_report_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/selfhost_client_fixture.dart';

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    resetSelfhostFixture();
    SharedPreferences.setMockInitialValues({
      'appMode': 'server',
      'baseUrl': 'https://fixture.test',
      'apiKey': 'synthetic',
    });
  });

  test(
    'identical pending pages share a request but later queries fetch fresh totals',
    () async {
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      await provider.init();
      final started = Completer<void>();
      final reply = Completer<void>();
      var requests = 0;
      await http.runWithClient(
        () async {
          final first = provider.readServerPage('traffic');
          await started.future;
          final second = provider.readServerPage('traffic');
          reply.complete();
          final pages = await Future.wait([first, second]);
          expect(pages.map((p) => p.total), [201, 201]);
          expect(requests, 1);
          expect((await provider.readServerPage('traffic')).total, 202);
          expect(requests, 2);
        },
        () => selfhostMockClient((request) async {
          requests++;
          if (!started.isCompleted) started.complete();
          await reply.future;
          return http.Response(
            jsonEncode({'data': [], 'total': 200 + requests}),
            200,
          );
        }),
      );
    },
  );

  testWidgets(
    'next page is prefetched without a limit-1 probe and navigation reuses it',
    (tester) async {
      final provider = ReportProvider();
      await provider.init();
      final requests = <Uri>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            ChangeNotifierProvider<ReportProvider>.value(
              value: provider,
              child: const MaterialApp(
                home: Scaffold(body: LocalPagedReportList(category: 'traffic')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(requests, hasLength(2));
          expect(requests.first.queryParameters['limit'], '200');
          expect(requests.last.queryParameters['offset'], '200');
          expect(find.textContaining('전체 401건'), findsOneWidget);
          await tester.tap(find.byTooltip('다음 페이지'));
          await tester.pumpAndSettle();
          expect(requests, hasLength(3));
          expect(requests.last.queryParameters['offset'], '400');
          expect(
            requests.where((r) => r.queryParameters['offset'] == '200'),
            hasLength(1),
          );
          provider.markDataChanged();
          await tester.pumpAndSettle();
          expect(
            requests.where((r) => r.queryParameters['offset'] == '0'),
            hasLength(2),
          );
          expect(
            requests.where((r) => r.queryParameters['offset'] == '200'),
            hasLength(2),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
        () => selfhostMockClient((request) async {
          requests.add(request.url);
          return http.Response(jsonEncode({'data': [], 'total': 401}), 200);
        }),
      );
      provider.dispose();
    },
  );

  for (final allCancel in [false, true]) {
    test(
      'shared page cancels transport only when all readers cancel: $allCancel',
      () async {
        final provider = ReportProvider();
        addTearDown(provider.dispose);
        await provider.init();
        final started = Completer<void>();
        final reply = Completer<void>();
        var firstCancelled = false;
        var secondCancelled = false;
        var requests = 0;
        _TrackedClient? pageClient;
        await http.runWithClient(
          () async {
            final first = provider.readServerPage(
              'traffic',
              isCancelled: () => firstCancelled,
            );
            await started.future;
            final second = provider.readServerPage(
              'traffic',
              isCancelled: () => secondCancelled,
            );
            // Install error listeners before the polling timer observes cancellation.
            final result = Future.wait([first, second]);
            final assertion = allCancel
                ? expectLater(result, throwsA(isA<QueryCancelled>()))
                : expectLater(result, completion(hasLength(2)));
            firstCancelled = true;
            secondCancelled = allCancel;
            if (allCancel) {
              await assertion.timeout(const Duration(seconds: 2));
              expect(pageClient!.closed, isTrue);
              reply.complete();
            } else {
              await Future<void>.delayed(const Duration(milliseconds: 120));
              expect(pageClient!.closed, isFalse);
              reply.complete();
              await assertion;
            }
            expect(requests, 1);
          },
          () {
            late _TrackedClient client;
            client = _TrackedClient((request) async {
              if (request.url.path == ServerContract.serverVersionPath) {
                return http.Response(jsonEncode(compatibleVersion), 200);
              }
              pageClient = client;
              requests++;
              if (!started.isCompleted) started.complete();
              await reply.future;
              return http.Response(jsonEncode({'data': [], 'total': 1}), 200);
            });
            return client;
          },
        );
      },
    );
  }
}
