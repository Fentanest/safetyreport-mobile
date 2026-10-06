// SQ-B03: Client → Standalone 전환의 대기 DB 가져오기.
// - 가져오기가 끝나기(또는 사용자가 버리기 전)까지 Standalone 모드를 켜지 않는다(동기화·drain·초기화가 빈 DB 에 먼저 쓰지 않게).
// - 실패하면 대기 작업을 남기고 "다시 시도 / 버리기"를 묻는다. 받은 파일 위치를 보여 준다.
// - 성공하거나 사용자가 버렸을 때만 대기 작업을 지운다.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/setup_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/pending_db_import_action.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/selfhost_client_fixture.dart';

const _path = '/storage/emulated/0/Documents/mysafetyreport/server_db_1.db';

class _RecordingProvider extends ReportProvider {
  _RecordingProvider(this.events);

  final List<String> events;

  @override
  Future<void> prepareStandaloneAccount(
    String username, {
    Future<bool> Function()? confirmAccountReset,
  }) async {
    events.add('verify-account');
  }

  @override
  Future<void> setStandaloneConfig(
    String username, {
    required String phoneNumber,
    bool isDemoMode = false,
    Future<bool> Function()? confirmAccountReset,
  }) async {
    events.add('activate:$username');
  }

  @override
  Future<void> refreshAll() async {}
}

void main() {
  late List<String> events;
  late int attempts;
  late int failUntil;

  setUp(() {
    events = [];
    attempts = 0;
    failUntil = 0;
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.pendingDbImport: 'convert:$_path',
    });
    SetupScreen.standaloneLoginOverride = (u, p) async => events.add('login');
    PendingDbImportAction.applyOverride = (action) async {
      attempts++;
      events.add('import#$attempts');
      if (attempts <= failUntil) throw Exception('디스크 공간 부족');
      return '서버 DB 변환 완료: 3건 임포트';
    };
  });

  tearDown(() {
    SetupScreen.standaloneLoginOverride = null;
    PendingDbImportAction.applyOverride = null;
  });

  Future<String?> pendingRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppPrefsKeys.pendingDbImport);
  }

  // 로그인 버튼의 진행 표시가 도는 동안에는 pumpAndSettle 이 끝나지 않는다.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> login(WidgetTester tester) async {
    final provider = _RecordingProvider(events);
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: SetupScreen(initialMode: AppMode.standalone),
        ),
      ),
    );
    await tester.enterText(find.widgetWithText(TextField, '아이디'), 'user');
    await tester.enterText(find.widgetWithText(TextField, '비밀번호'), 'pw');
    await tester.enterText(
      find.widgetWithText(TextField, '휴대폰번호'),
      '010-1234-5678',
    );
    await tester.tap(find.text('로그인'));
    await settle(tester);
  }

  testWidgets('imports before the Standalone mode is activated and clears '
      'the action only after success', (tester) async {
    await login(tester);

    expect(events, ['login', 'verify-account', 'import#1', 'activate:user']);
    expect(await pendingRaw(), isNull);
    expect(find.textContaining('서버 DB 변환 완료'), findsOneWidget);
  });

  testWidgets('failure keeps the action, does not activate the mode, shows '
      'the file path and retry succeeds', (tester) async {
    failUntil = 1;
    await login(tester);

    expect(find.text('DB 가져오기 실패'), findsOneWidget);
    expect(find.textContaining(_path), findsOneWidget);
    expect(events, [
      'login',
      'verify-account',
      'import#1',
    ], reason: '가져오기 전에는 모드를 켜지 않는다');
    expect(await pendingRaw(), 'convert:$_path', reason: '실패하면 지우지 않는다');

    // 뒤로가기로 닫히지 않는다(결정 없이 모드가 켜지면 안 된다).
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('DB 가져오기 실패'), findsOneWidget);

    await tester.tap(find.text('다시 시도'));
    await settle(tester);

    expect(events, [
      'login',
      'verify-account',
      'import#1',
      'import#2',
      'activate:user',
    ]);
    expect(await pendingRaw(), isNull);
  });

  testWidgets('discard removes the action, keeps the downloaded file path in '
      'the notice and starts with an empty DB', (tester) async {
    failUntil = 99;
    await login(tester);

    expect(find.text('DB 가져오기 실패'), findsOneWidget);
    await tester.tap(find.text('버리고 빈 DB로 시작'));
    await settle(tester);

    expect(events, ['login', 'verify-account', 'import#1', 'activate:user']);
    expect(await pendingRaw(), isNull);
    expect(find.textContaining(_path), findsOneWidget, reason: '받은 파일 위치 안내');
  });

  // SQ-B09: 서버 연결 확인 중 화면을 닫으면 응답 뒤 setState 하지 않는다.
  testWidgets('SQ-B09 leaving the server setup during the connection check '
      'does not call setState after dispose', (tester) async {
    resetSelfhostFixture();
    final release = Completer<void>();
    await http.runWithClient(
      () async {
        final provider = _RecordingProvider(events);
        addTearDown(provider.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<ReportProvider>.value(
            value: provider,
            child: MaterialApp(
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const SetupScreen(initialMode: AppMode.server),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, '서버 URL'),
          'https://fixture.test',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'API Key'),
          'synthetic',
        );
        await tester.tap(find.text('연결 확인 후 시작하기'));
        await tester.pump();
        await tester.binding.handlePopRoute();
        await settle(tester);
        expect(find.byType(SetupScreen), findsNothing);
        release.complete();
        await settle(tester);
        expect(tester.takeException(), isNull);
      },
      () => selfhostMockClient((request) async {
        await release.future;
        return http.Response('{}', 500);
      }),
    );
  });
}
