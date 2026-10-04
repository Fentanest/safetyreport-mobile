// SQ-B08: Client 서버 주소를 바꾸면 이전 서버의 기능 목록(capabilities)을 버리고, 새 서버에서 받기 전까지는
// "알 수 없음"으로 둔다(기능 게이트 UI 를 숨긴다). 새 서버 조회가 실패해도 이전 서버의 목록이 되살아나지 않는다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/selfhost_client_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

  setUp(() {
    resetSelfhostFixture();
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'https://a.test',
      AppPrefsKeys.apiKey: 'synthetic',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(perm, (_) async => true);
    BackgroundLoginCheck.schedulingEnabled = false;
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(perm, null);
    BackgroundLoginCheck.schedulingEnabled = true;
  });

  http.Response config(List<String> capabilities) => http.Response(
    jsonEncode({
      'data': {'capabilities': capabilities},
    }),
    200,
  );

  test(
    'switching servers clears capabilities until the new server answers',
    () async {
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      await provider.init();
      expect(provider.serverCapabilitiesKnown, isFalse);

      await http.runWithClient(
        () => provider.fetchAppConfig(),
        () => selfhostMockClient(
          (_) async => config([ServerContract.communityAccountCapability]),
        ),
      );
      expect(provider.communityAccountSupported, isTrue);
      expect(provider.serverCapabilitiesKnown, isTrue);

      await provider.setConfig('https://b.test', 'synthetic');
      expect(provider.communityAccountSupported, isFalse);
      expect(provider.serverCapabilitiesKnown, isFalse);

      // 새 서버(구버전) 조회 실패 — 이전 서버 목록이 남거나 되살아나면 안 된다.
      await http.runWithClient(
        () => provider.fetchAppConfig(),
        () => selfhostMockClient((_) async => http.Response('{}', 404)),
      );
      expect(provider.communityAccountSupported, isFalse);
      expect(provider.serverCapabilitiesKnown, isFalse);

      await http.runWithClient(
        () => provider.fetchAppConfig(),
        () => selfhostMockClient((_) async => config(const [])),
      );
      expect(provider.serverCapabilitiesKnown, isTrue);
      expect(provider.communityAccountSupported, isFalse);
    },
  );

  test('a fetch for the old server still in flight does not block or '
      'overwrite the new server fetch', () async {
    final provider = ReportProvider();
    addTearDown(provider.dispose);
    await provider.init();
    final releaseA = Completer<void>();
    final hosts = <String>[];

    await http.runWithClient(
      () async {
        final oldFetch = provider.fetchAppConfig();
        await pumpEventQueue();
        await provider.setConfig('https://b.test', 'synthetic');
        final newFetch = provider.fetchAppConfig();
        releaseA.complete();
        await Future.wait([oldFetch, newFetch]);
      },
      () => selfhostMockClient((request) async {
        if (request.url.path != ServerContract.appConfigPath) {
          return http.Response('{}', 404);
        }
        hosts.add(request.url.host);
        if (request.url.host == 'a.test') {
          await releaseA.future;
          return config([ServerContract.communityAccountCapability]);
        }
        return config(const []);
      }),
    );

    expect(hosts, containsAll(['a.test', 'b.test']));
    expect(provider.serverCapabilitiesKnown, isTrue);
    expect(provider.communityAccountSupported, isFalse);
  });

  test('switching to Standalone clears Client capabilities', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final provider = ReportProvider();
    addTearDown(provider.dispose);
    await provider.init();
    await http.runWithClient(
      () => provider.fetchAppConfig(),
      () => selfhostMockClient((_) async => config(['rating_cause'])),
    );
    expect(provider.serverCapabilitiesKnown, isTrue);
    await provider.setStandaloneConfig(
      'demo',
      phoneNumber: 'demo',
      isDemoMode: true,
    );
    expect(provider.serverCapabilitiesKnown, isFalse);
  });
}
