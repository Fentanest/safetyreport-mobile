// SQ-P01: 테마는 한 번만 만들고, 루트는 자기가 쓰는 값이 바뀔 때만 MaterialApp 을 다시 만든다.
// 새 ThemeData 는 WidgetStateProperty.resolveWith 때문에 항상 "다른 테마"로 판정돼 AnimatedTheme 이 200ms 보간을 돈다.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/app_theme_mode.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/setup_screen.dart';
import 'package:safetyreport/services/server_connection_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Gate extends CommunityGate {
  _Gate() : super(configStatus: () => 'ok');

  bool enter = true;

  void poke() => notifyListeners();

  @override
  bool get canEnter => enter;

  @override
  bool get isChecked => true;

  @override
  Future<GateState> refreshNow({bool silent = false}) async => state;

  @override
  void startPolling() {}
}

void main() {
  test('AppTheme.light()/dark() return the same cached ThemeData', () {
    expect(identical(AppTheme.light(), AppTheme.light()), isTrue);
    expect(identical(AppTheme.dark(), AppTheme.dark()), isTrue);
    expect(AppTheme.light().brightness, Brightness.light);
    expect(AppTheme.dark().brightness, Brightness.dark);
  });

  testWidgets(
    'provider/gate notify without root input change keeps MaterialApp and theme',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        perm,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          perm,
          null,
        ),
      );
      final provider = ReportProvider();
      await provider.init();
      final gate = _Gate();
      addTearDown(gate.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ReportProvider>.value(value: provider),
            ChangeNotifierProvider<CommunityGate>.value(value: gate),
            ChangeNotifierProvider(
              create: (_) => NotificationHistoryProvider(),
            ),
          ],
          child: SafetyReportApp(
            serverVersionCheck: (_, _) async =>
                ServerConnectionResult.ok(normalizedUrl: 'http://test'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SetupScreen), findsOneWidget);

      final before = tester.widget<MaterialApp>(find.byType(MaterialApp));
      provider.bumpStatsRefresh();
      gate.poke();
      await tester.pump();
      expect(
        identical(tester.widget<MaterialApp>(find.byType(MaterialApp)), before),
        isTrue,
        reason: '루트 입력이 그대로면 MaterialApp 을 다시 만들지 않는다',
      );
      expect(tester.binding.hasScheduledFrame, isFalse, reason: '테마 보간 프레임 없음');
      expect(find.byType(SetupScreen), findsOneWidget);

      await provider.setThemeMode(AppThemeMode.dark);
      await tester.pumpAndSettle();
      final after = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(after.themeMode, ThemeMode.dark, reason: '테마 설정 변경은 반영된다');
      expect(identical(after.darkTheme, AppTheme.dark()), isTrue);
    },
  );
}
