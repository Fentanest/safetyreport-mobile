import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/auth_status_notice.dart';

class _ModeProvider extends ReportProvider {
  _ModeProvider(this._mode, {this.demo = false});
  final AppMode _mode;
  final bool demo;

  @override
  AppMode get appMode => _mode;

  @override
  bool get isStandaloneDemo => demo;
}

Future<void> _pump(WidgetTester tester, ReportProvider provider) =>
    tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.build(Brightness.light),
          home: const Scaffold(body: ReloginRequiredBanner()),
        ),
      ),
    );

void main() {
  tearDown(() => StandaloneAuthService.status.value = null);

  ReloginStatus status(ReloginOutcome o) =>
      ReloginStatus(DateTime(2026, 9, 24, 9), o, '사유 메시지');

  testWidgets('비밀번호 거부·로그인 정보 없음일 때만 재로그인 경고를 보인다', (tester) async {
    final provider = _ModeProvider(AppMode.standalone);
    addTearDown(provider.dispose);
    await _pump(tester, provider);
    expect(find.text('안전신문고 재로그인이 필요합니다'), findsNothing);

    StandaloneAuthService.status.value = status(ReloginOutcome.transient);
    await tester.pump();
    expect(find.text('안전신문고 재로그인이 필요합니다'), findsNothing);

    StandaloneAuthService.status.value = status(ReloginOutcome.rejected);
    await tester.pump();
    expect(find.text('안전신문고 재로그인이 필요합니다'), findsOneWidget);
    expect(find.text('사유 메시지'), findsOneWidget);
    expect(find.text('재로그인'), findsOneWidget);
  });

  testWidgets('데모·Client 모드에서는 보이지 않는다', (tester) async {
    StandaloneAuthService.status.value = status(ReloginOutcome.rejected);
    for (final provider in [
      _ModeProvider(AppMode.standalone, demo: true),
      _ModeProvider(AppMode.server),
    ]) {
      addTearDown(provider.dispose);
      await _pump(tester, provider);
      expect(find.text('안전신문고 재로그인이 필요합니다'), findsNothing);
    }
  });
}
