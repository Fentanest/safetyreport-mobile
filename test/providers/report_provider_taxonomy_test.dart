// Astra #5(2026-10-11): 새 앱이 구서버(report_taxonomy 없음)에 연결하면 안전신고·생활불편
// 조회(`/reports/safety|living`)를 보내지 않고 3분류(교통위반·주정차·기타)로 동작해야 한다.
// `ServerVersionInfo.supportsFiveCategories` 가 선언만 있고 쓰이지 않던 결함의 회귀 테스트.
//
// Astra 재검수(2026-10-11, #5-A/#5-B): 아래 세 시험은 그 결함을 고치며 생긴 두 가지 추가 결함의
// 회귀 시험이다.
// A. 능력 확인 전·조회 실패 후에도 구서버에 안전신고·생활불편을 요청해 400 이 날 수 있었다.
// B. `refreshServerTaxonomySupport` 가 응답 적용 전에 연결(epoch·baseUrl·apiKey)이 바뀌었는지
//    확인하지 않아, 이전 서버의 늦은 응답이 그 사이 바뀐 서버의 판정을 덮을 수 있었다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/selfhost_client_fixture.dart';

/// 구서버(3분류, protocol 3 호환이지만 report_taxonomy 가 없음)와 신서버(5분류)의
/// `/server/version` 응답. protocol_version·supported_client_protocols 는
/// ClientCompatibility.ensure 가 먼저 통과시켜야 하는 값이다(taxonomy 와 별개).
const _legacyVersion = {
  'version': '3.4.0',
  'protocol_version': 3,
  'supported_client_protocols': [3],
};
const _fiveCategoryVersion = {
  'version': '3.5.0',
  'protocol_version': 3,
  'supported_client_protocols': [3],
  'report_taxonomy': 5,
};

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

  http.Response pageResponse() =>
      http.Response(jsonEncode({'data': [], 'total': 0}), 200);

  test('구서버(report_taxonomy 없음): 3분류로 보고 안전신고·생활불편은 요청 자체를 보내지 않는다', () async {
    final provider = await clientProvider();
    final requested = <String>[];

    await http.runWithClient(
      () async {
        await provider.refreshServerTaxonomySupport();
        expect(provider.supportsFiveCategories, isFalse);

        final safety = await provider.readServerPage('safety');
        final living = await provider.readServerPage('living');
        expect(safety.total, 0);
        expect(safety.reports, isEmpty);
        expect(living.total, 0);
        expect(living.reports, isEmpty);

        // 구서버에는 없는 엔드포인트라 400 이 난다 — 그 요청 자체가 없었는지 확인한다.
        expect(requested, isNot(contains('safety')));
        expect(requested, isNot(contains('living')));

        // 3분류(교통위반·주정차·기타)는 평소대로 서버에 요청한다.
        final traffic = await provider.readServerPage('traffic');
        expect(traffic.total, 0);
        expect(requested, contains('traffic'));
      },
      () => MockClient((request) async {
        if (request.url.path == ServerContract.serverVersionPath) {
          // 구서버: protocol 3 호환이지만 report_taxonomy 키가 없다.
          return http.Response(jsonEncode(_legacyVersion), 200);
        }
        final match = RegExp(r'/reports/([a-z]+)/page$').firstMatch(
          request.url.path,
        );
        if (match != null) {
          final category = match.group(1)!;
          requested.add(category);
          if (category == 'safety' || category == 'living') {
            // 구서버는 이 분류를 모른다 — 400 Invalid category.
            return http.Response('{"detail":"Invalid category"}', 400);
          }
          return pageResponse();
        }
        return http.Response('not found', 404);
      }),
    );
  });

  test('신서버(report_taxonomy=5): 5분류 그대로 안전신고·생활불편도 요청한다', () async {
    final provider = await clientProvider();
    final requested = <String>[];

    await http.runWithClient(
      () async {
        await provider.refreshServerTaxonomySupport();
        expect(provider.supportsFiveCategories, isTrue);

        final safety = await provider.readServerPage('safety');
        expect(safety.total, 0);
        expect(requested, contains('safety'));
      },
      () => MockClient((request) async {
        if (request.url.path == ServerContract.serverVersionPath) {
          return http.Response(jsonEncode(_fiveCategoryVersion), 200);
        }
        final match = RegExp(r'/reports/([a-z]+)/page$').firstMatch(
          request.url.path,
        );
        if (match != null) {
          requested.add(match.group(1)!);
          return pageResponse();
        }
        return http.Response('not found', 404);
      }),
    );
  });

  test('Standalone 은 항상 5분류다(서버 조회 없음)', () async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'fixture',
      AppPrefsKeys.standalonePhoneNumber: 'fixture',
    });
    final provider = ReportProvider();
    addTearDown(provider.dispose);
    await provider.init();
    expect(provider.supportsFiveCategories, isTrue);
  });

  test('조회 실패(네트워크 오류)는 이전 값을 유지한다', () async {
    final provider = await clientProvider();
    await http.runWithClient(
      () => provider.refreshServerTaxonomySupport(),
      () => MockClient((request) async {
        if (request.url.path == ServerContract.serverVersionPath) {
          return http.Response(jsonEncode(_fiveCategoryVersion), 200);
        }
        return http.Response('not found', 404);
      }),
    );
    expect(provider.supportsFiveCategories, isTrue);

    await http.runWithClient(
      () => provider.refreshServerTaxonomySupport(),
      () => MockClient((request) async => http.Response('fail', 500)),
    );
    // 500 은 ServerVersionInfo.empty(hasVersion=false) — 이전에 안 known 값을 유지한다.
    expect(provider.supportsFiveCategories, isTrue);
  });

  test(
    'safety·living 동시 조회: 미확인이면 확인을 먼저 기다리고, 확인은 한 번만 공유한다(Astra #5-A, 신규 회귀)',
    () async {
      final provider = await clientProvider();
      final versionCompleter = Completer<http.Response>();
      var taxonomyProbeCount = 0;
      var safetyCallCount = 0;
      var livingCallCount = 0;

      await http.runWithClient(
        () async {
          // 호출자(예: 신고내역 탭)는 확인 완료를 기다리지 않고 바로 안전신고·생활불편을 동시에
          // 조회할 수 있다 — _PostGateFlow 가 unawaited 로 서비스를 시작하는 것과 같은 모양.
          final safetyFuture = provider.readServerPage('safety');
          final livingFuture = provider.readServerPage('living');

          // 확인 응답이 아직 안 왔다 — 실제 페이지 요청이 먼저 나가면 안 된다(Astra #5-A).
          await pumpEventQueue();
          expect(safetyCallCount, 0, reason: '확인 전에 안전신고 페이지를 요청했다');
          expect(livingCallCount, 0, reason: '확인 전에 생활불편 페이지를 요청했다');
          expect(taxonomyProbeCount, 1, reason: '두 분류가 동시에 물어도 확인은 공유 Future 로 한 번만');

          versionCompleter.complete(
            http.Response(jsonEncode(_legacyVersion), 200),
          );

          final safety = await safetyFuture;
          final living = await livingFuture;
          expect(safety.total, 0);
          expect(safety.reports, isEmpty);
          expect(living.total, 0);
          expect(living.reports, isEmpty);
          expect(taxonomyProbeCount, 1);
          // 확인 결과 구서버로 밝혀졌으므로 실제 페이지 요청 자체가 없어야 한다.
          expect(safetyCallCount, 0);
          expect(livingCallCount, 0);
          expect(provider.supportsFiveCategories, isFalse);
        },
        () => MockClient((request) async {
          if (request.url.path == ServerContract.serverVersionPath) {
            // ClientCompatibility.ensure 의 호환성 확인(Content-Type 헤더 포함)은 즉시 통과시키고,
            // refreshServerTaxonomySupport 의 분류 지원 확인(Content-Type 없음)만 지연시킨다 —
            // 두 확인이 같은 경로를 쓰므로 헤더로 구분한다.
            if (request.headers.containsKey('Content-Type')) {
              return http.Response(jsonEncode(_legacyVersion), 200);
            }
            taxonomyProbeCount++;
            return versionCompleter.future;
          }
          final match = RegExp(
            r'/reports/([a-z]+)/page$',
          ).firstMatch(request.url.path);
          if (match != null) {
            final category = match.group(1)!;
            if (category == 'safety') safetyCallCount++;
            if (category == 'living') livingCallCount++;
            return http.Response('{"detail":"Invalid category"}', 400);
          }
          return http.Response('not found', 404);
        }),
      );
    },
  );

  test(
    '능력 확인이 실패해 미확인이 유지돼도 요청은 보내고, 400 이면 그때 구서버로 확정한다(Astra #5-A, 신규 회귀)',
    () async {
      final provider = await clientProvider();
      var safetyCallCount = 0;

      await http.runWithClient(
        () async {
          final result = await provider.readServerPage('safety');
          expect(result.total, 0);
          expect(result.reports, isEmpty);
          // 확인 자체가 실패해도(이전 값 유지 규칙) 요청은 평소대로 보냈다.
          expect(safetyCallCount, 1);
          // 그 요청이 400 으로 실패했으므로 그 자리에서 구서버로 확정한다.
          expect(provider.supportsFiveCategories, isFalse);
        },
        () => MockClient((request) async {
          if (request.url.path == ServerContract.serverVersionPath) {
            if (request.headers.containsKey('Content-Type')) {
              return http.Response(jsonEncode(_legacyVersion), 200);
            }
            return http.Response('fail', 500); // 분류 지원 확인 자체가 실패 — 미확인 유지.
          }
          final match = RegExp(
            r'/reports/([a-z]+)/page$',
          ).firstMatch(request.url.path);
          if (match != null && match.group(1) == 'safety') {
            safetyCallCount++;
            return http.Response('{"detail":"Invalid category"}', 400);
          }
          return http.Response('not found', 404);
        }),
      );
    },
  );

  test(
    '이전 서버의 늦은 응답이 그 사이 바뀐 연결의 분류 지원 여부를 덮지 않는다(Astra #5-B, 신규 회귀)',
    () async {
      final provider = await clientProvider(); // baseUrl: https://a.test
      final completerA = Completer<http.Response>();

      await http.runWithClient(
        () async {
          // A 서버 확인을 시작하되 응답은 미룬다.
          final pendingA = provider.refreshServerTaxonomySupport();

          // 그 응답이 오기 전에 B 서버로 연결을 바꾼다.
          await provider.setConfig('https://b.test', 'synthetic-b');
          expect(provider.supportsFiveCategories, isTrue); // 미확인 기본값.

          // B 서버는 바로 응답한다(5분류).
          await provider.refreshServerTaxonomySupport();
          expect(provider.supportsFiveCategories, isTrue);

          // A 의 느린 응답이 이제 도착한다(3분류) — 이미 B 로 바뀐 지금 연결의 판정을 덮으면
          // 안 된다.
          completerA.complete(http.Response(jsonEncode(_legacyVersion), 200));
          await pendingA;

          expect(provider.baseUrl, 'https://b.test');
          expect(provider.supportsFiveCategories, isTrue);
        },
        () => MockClient((request) async {
          if (request.url.path == ServerContract.serverVersionPath) {
            if (request.url.host == 'a.test') return completerA.future;
            return http.Response(jsonEncode(_fiveCategoryVersion), 200);
          }
          return http.Response('not found', 404);
        }),
      );
    },
  );
}
