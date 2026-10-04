// 설정 화면(Client) 흐름 회귀:
// - SQ-B06: 서버 DB 다운로드 진행 창을 Android 뒤로가기로 닫으면 다운로드가 계속되고, 끝나면 "진행 창 닫기" pop 이
//   설정 화면을 닫았다. 이제 뒤로가기 = 다운로드 취소, 진행 창은 자기 route 로만 닫는다.
// - SQ-B08: "저장"에 진행 중 잠금이 없어 두 번 누르거나 연결 테스트 중에 누르면 setConfig 가 두 번 돌았다.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/selfhost_client_fixture.dart';

class _Provider extends ReportProvider {
  int setConfigCalls = 0;
  int resetCalls = 0;

  @override
  Future<void> setConfig(String url, String key) async {
    setConfigCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  @override
  Future<void> resetConfig() async => resetCalls++;

  @override
  Future<void> refreshAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

  setUp(() {
    resetSelfhostFixture();
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'https://fixture.test',
      AppPrefsKeys.apiKey: 'synthetic',
    });
    PackageInfo.setMockInitialValues(
      appName: 'safetyreport',
      packageName: 'x',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(perm, (_) async => false);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(perm, null);
  });

  Future<_Provider> pumpSettings(WidgetTester tester) async {
    final provider = _Provider();
    await provider.init();
    await tester.binding.setSurfaceSize(const Size(900, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                  child: const Text('open settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    return provider;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  http.Response ok(Object data) =>
      http.Response(jsonEncode({'data': data}), 200);

  testWidgets(
    'SQ-B06 back on the server DB download dialog cancels the download and '
    'keeps the settings screen and mode',
    (tester) async {
      final release = Completer<void>();
      var dbRequests = 0;
      await http.runWithClient(
        () async {
          final provider = await pumpSettings(tester);
          addTearDown(provider.dispose);

          await tester.ensureVisible(find.text('변경'));
          await tester.tap(find.text('변경'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('서버 DB 받아 변환'));
          await settle(tester);
          expect(find.textContaining('서버 DB 다운로드 중'), findsOneWidget);
          expect(dbRequests, 1);

          // Android 뒤로가기
          await tester.binding.handlePopRoute();
          if (!release.isCompleted) release.complete();
          await settle(tester);

          expect(find.textContaining('서버 DB 다운로드 중'), findsNothing);
          expect(
            find.byType(SettingsScreen),
            findsOneWidget,
            reason: '진행 창 닫기용 pop 이 설정 화면을 닫으면 안 된다',
          );
          expect(find.textContaining('취소했습니다'), findsOneWidget);
          expect(provider.resetCalls, 0, reason: '모드는 바꾸지 않는다');
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString(AppPrefsKeys.pendingDbImport), isNull);
        },
        () => selfhostMockClient((request) async {
          if (request.url.path == ServerContract.settingsDbPath) {
            dbRequests++;
            await release.future;
            throw http.ClientException('closed');
          }
          return ok(<String, Object>{'total': 1});
        }),
      );
    },
  );

  testWidgets('SQ-B08 save cannot run twice while saving', (tester) async {
    final release = Completer<void>();
    await http.runWithClient(
      () async {
        final provider = await pumpSettings(tester);
        addTearDown(provider.dispose);
        final save = find.widgetWithText(FilledButton, '저장');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pump();
        await tester.tap(save, warnIfMissed: false);
        await tester.pump();
        release.complete();
        await settle(tester);
        expect(provider.setConfigCalls, 1);
      },
      () => selfhostMockClient((request) async {
        if (request.url.path == ServerContract.summaryPath) {
          await release.future;
        }
        return ok(<String, Object>{'total': 1});
      }),
    );
  });

  testWidgets('SQ-B08 save is disabled while a connection test runs', (
    tester,
  ) async {
    final release = Completer<void>();
    await http.runWithClient(
      () async {
        final provider = await pumpSettings(tester);
        addTearDown(provider.dispose);
        final test = find.widgetWithText(OutlinedButton, '연결 테스트');
        await tester.ensureVisible(test);
        await tester.tap(test);
        await settle(tester);
        final save = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, '저장'),
        );
        expect(save.onPressed, isNull);
        release.complete();
        await settle(tester);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '저장'))
              .onPressed,
          isNotNull,
        );
        expect(provider.setConfigCalls, 0);
      },
      () => selfhostMockClient((request) async {
        if (request.url.path == ServerContract.summaryPath) {
          await release.future;
        }
        return ok(<String, Object>{'total': 1});
      }),
    );
  });

  // SQ-B09: await 뒤 화면이 닫혔으면 setState 하지 않는다.
  testWidgets('SQ-B09 closing settings during the WS toggle delay does not '
      'call setState after dispose', (tester) async {
    await http.runWithClient(() async {
      final provider = await pumpSettings(tester);
      addTearDown(provider.dispose);
      final toggle = find.text('서비스 시작');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    }, () => selfhostMockClient((_) async => ok(<String, Object>{'total': 1})));
  });

  testWidgets('SQ-B09 closing settings during a connection test does not '
      'call setState after dispose', (tester) async {
    final release = Completer<void>();
    await http.runWithClient(
      () async {
        final provider = await pumpSettings(tester);
        addTearDown(provider.dispose);
        final test = find.widgetWithText(OutlinedButton, '연결 테스트');
        await tester.ensureVisible(test);
        await tester.tap(test);
        await settle(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(SettingsScreen), findsNothing);
        release.complete();
        await settle(tester);
        expect(tester.takeException(), isNull);
      },
      () => selfhostMockClient((request) async {
        if (request.url.path == ServerContract.summaryPath) {
          await release.future;
        }
        return ok(<String, Object>{'total': 1});
      }),
    );
  });
}
