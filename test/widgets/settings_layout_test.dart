// SQ-U17: 설정 화면 순서·중복 정리. 기능은 그대로 두고 순서만 바꾼다.
// 연결·계정(맨 위 도움·문의) → 데이터 관리 → 표시(테마 3칸 세그먼트) → 목록·통계 기준 → 권한 → 정보.
// 버그 제보는 한 곳, 설정 맨 위(연결 방식 카드 바로 아래 — 2026-09-24 결정). 앱 정보에는 정부 출처 링크와 비공식 고지가 남는다(PROJECT_RULES §1).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/app_theme_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/selfhost_client_fixture.dart';

class _DemoProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;

  @override
  bool get isStandaloneDemo => true;

  @override
  Future<void> refreshAll() async {}
}

class _ClientProvider extends ReportProvider {
  @override
  Future<void> refreshAll() async {}
}

const _sections = [
  'connection',
  'data',
  'display',
  'list-basis',
  'permissions',
  'about',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

  setUp(() {
    resetSelfhostFixture();
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

  Future<void> pumpSettings(
    WidgetTester tester,
    ReportProvider provider, {
    Size size = const Size(900, 6000),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const SettingsScreen(),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  double topOf(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  Finder section(String key) => find.byKey(ValueKey('settings-section-$key'));

  void expectSectionOrder(WidgetTester tester) {
    final tops = [for (final s in _sections) topOf(tester, section(s))];
    for (var i = 1; i < tops.length; i++) {
      expect(
        tops[i],
        greaterThan(tops[i - 1]),
        reason: '${_sections[i - 1]} → ${_sections[i]} 순서',
      );
    }
  }

  /// [finder] 가 [from] 묶음 머리와 그다음 묶음 머리 사이에 있는지.
  void expectInSection(WidgetTester tester, Finder finder, String from) {
    final i = _sections.indexOf(from);
    final y = topOf(tester, finder);
    expect(y, greaterThan(topOf(tester, section(from))), reason: '$from 아래');
    if (i + 1 < _sections.length) {
      expect(
        y,
        lessThan(topOf(tester, section(_sections[i + 1]))),
        reason: '${_sections[i + 1]} 위',
      );
    }
  }

  http.Response ok(Object data) =>
      http.Response(jsonEncode({'data': data}), 200);

  testWidgets('Client: sections in order, mode-only cards kept in place', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'https://fixture.test',
      AppPrefsKeys.apiKey: 'synthetic',
    });
    await http.runWithClient(() async {
      final provider = _ClientProvider();
      await provider.init();
      addTearDown(provider.dispose);
      await pumpSettings(tester, provider);

      expectSectionOrder(tester);
      expectInSection(tester, find.text('서버 연결'), 'connection');
      expectInSection(tester, find.text('백그라운드 서버 연결'), 'connection');
      expectInSection(tester, find.text('DB 백업 (다운로드)'), 'data');
      expectInSection(tester, find.text('파일 관리 (서버 파일)'), 'data');
      expectInSection(tester, find.text('크롤링 자동 저장'), 'data');
      expectInSection(tester, find.text('화면 테마'), 'display');
      expectInSection(tester, find.text('취하 데이터 숨기기'), 'list-basis');
      expectInSection(tester, find.text('중복 신고 대표건만 반영'), 'list-basis');
      expectInSection(tester, find.text('권한 설정'), 'permissions');
      // 버그 제보(도움·문의)는 맨 위: 연결 방식 카드 바로 아래, 서버 연결 카드보다 위(2026-09-24 결정).
      expectInSection(tester, find.text('도움·문의'), 'connection');
      expect(
        topOf(tester, find.text('버그 제보하기')),
        lessThan(topOf(tester, find.text('서버 연결'))),
      );
      expect(
        topOf(tester, find.text('버그 제보하기')),
        greaterThan(topOf(tester, find.text('변경'))),
      );
      expectInSection(tester, find.text('앱 정보'), 'about');
      expect(find.text('안전신문고 계정'), findsNothing);
    }, () => selfhostMockClient((_) async => ok(<String, Object>{})));
  });

  testWidgets('Standalone demo: account card instead of server cards', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'demo',
    });
    final provider = _DemoProvider();
    addTearDown(provider.dispose);
    await pumpSettings(tester, provider);

    expectSectionOrder(tester);
    expectInSection(tester, find.text('안전신문고 계정'), 'connection');
    expect(find.text('서버 연결'), findsNothing);
    expect(find.text('크롤링 자동 저장'), findsNothing);
    expect(find.text('백그라운드 서버 연결'), findsNothing);
    expectInSection(tester, find.text('파일 관리 (내보낸 파일 · Excel)'), 'data');
  });

  testWidgets('single bug-report entry; 앱 정보 keeps source link and notice; '
      'filter card renamed', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'demo',
    });
    final provider = _DemoProvider();
    addTearDown(provider.dispose);
    await pumpSettings(tester, provider);

    expect(find.text('버그 제보하기'), findsOneWidget);
    expect(find.text('기타 데이터 필터 세팅'), findsNothing);
    expect(find.text('목록·통계 기준'), findsWidgets);

    final infoCard = find.ancestor(
      of: find.text('앱 정보'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(
        of: infoCard,
        matching: find.text('https://www.safetyreport.go.kr/'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: infoCard, matching: find.text('안전신문고 공식 사이트 열기')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: infoCard,
        matching: find.textContaining('이 앱은 안전신문고의 공식 앱이 아니며'),
      ),
      findsOneWidget,
    );
    // 라디오 목록·설명 상자는 없어졌다.
    expect(find.byType(RadioListTile<AppThemeMode>), findsNothing);
  });

  testWidgets('theme segmented control changes the theme mode', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'demo',
    });
    final provider = _DemoProvider();
    addTearDown(provider.dispose);
    await pumpSettings(tester, provider);
    final control = find.byKey(const ValueKey('settings-theme-mode'));
    expect(control, findsOneWidget);
    expect(provider.themeMode, AppThemeMode.system);

    await tester.tap(find.descendant(of: control, matching: find.text('다크')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(provider.themeMode, AppThemeMode.dark);

    await tester.tap(find.descendant(of: control, matching: find.text('라이트')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(provider.themeMode, AppThemeMode.light);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppPrefsKeys.themeMode), 'light');
  });

  testWidgets('narrow width at 2.0x text renders without overflow', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'demo',
    });
    final provider = _DemoProvider();
    addTearDown(provider.dispose);
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await pumpSettings(
        tester,
        provider,
        size: const Size(360, 9000),
        textScale: 2.0,
      );
    } finally {
      FlutterError.onError = previous;
    }
    expect(errors.map((e) => e.exceptionAsString().split("\n").first), isEmpty);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);
  });
}
