// Astra #5(2026-10-11): 새 앱이 구서버(report_taxonomy 없음)에 연결하면 안전신고·생활불편
// 조회(`/reports/safety|living`)를 보내지 않고 3분류(교통위반·주정차·기타)로 동작해야 한다.
// `ServerVersionInfo.supportsFiveCategories` 가 선언만 있고 쓰이지 않던 결함의 회귀 테스트.
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
}
