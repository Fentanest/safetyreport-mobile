// SQ-P10 — 전국 신고현황 자동 넘김(5초)은 화면이 안 보이면(숨은 탭 TickerMode off, 앱 백그라운드) 멈춘다.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/sunwi.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/sunwi_screen.dart';
import 'package:safetyreport/services/repositories/sunwi_repository.dart';
import 'package:safetyreport/theme/app_theme.dart';

class _FakeRepo implements SunwiRepository {
  _FakeRepo([this.gate]);
  final Completer<void>? gate;

  @override
  Future<SunwiSnapshot> fetch({
    void Function(int completed, int total, String label)? onProgress,
  }) async {
    await gate?.future;
    return SunwiSnapshot(payload: _payload);
  }
}

SunwiChildCategory _child(String name) =>
    SunwiChildCategory(name: name, fullName: '$name 전체', items: const []);

final _payload = SunwiPayload(
  available: true,
  period: '',
  periodLabel: '',
  updatedAt: '',
  categories: [
    SunwiParentCategory(name: '교통', children: [_child('소A'), _child('소B')]),
    SunwiParentCategory(name: '생활', children: [_child('소C'), _child('소D')]),
  ],
  error: '',
  failedCount: 0,
  csvDownloadUrl: '',
  allCsvDownloadUrl: '',
);

void _toBackground(WidgetTester tester) {
  for (final s in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void _toForeground(WidgetTester tester) {
  for (final s in const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void main() {
  late ReportProvider provider;
  setUp(() {
    SunwiSection.debugClearCache();
    provider = ReportProvider();
  });
  tearDown(() {
    provider.dispose();
    SunwiSection.debugClearCache();
  });

  Widget host(ValueNotifier<bool> visible, SunwiRepository repo) =>
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, on, _) => TickerMode(
                enabled: on,
                child: SunwiSection(repository: repo),
              ),
            ),
          ),
        ),
      );

  testWidgets('auto-advance pauses while TickerMode is disabled', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(host(visible, _FakeRepo()));
    await tester.pump();
    await tester.pump();
    expect(find.text('소A'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('소B'), findsOneWidget, reason: 'advances while visible');

    visible.value = false; // 다른 탭으로 이동
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('소B'), findsOneWidget, reason: 'hidden tab must not page');

    visible.value = true;
    await tester.pump();
    expect(find.text('소B'), findsOneWidget, reason: 'no jump on return');
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('소C'), findsOneWidget, reason: 'resumes when visible');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('auto-advance pauses while the app is in background', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(host(visible, _FakeRepo()));
    await tester.pump();
    await tester.pump();
    expect(find.text('소A'), findsOneWidget);

    _toBackground(tester);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('소A'), findsOneWidget, reason: 'background must not page');

    _toForeground(tester);
    await tester.pump();
    expect(find.text('소A'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('소B'), findsOneWidget, reason: 'resumes on resume');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no auto-page timer is created after dispose mid-load', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final gate = Completer<void>();
    await tester.pumpWidget(host(visible, _FakeRepo(gate)));
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pump();
    // 테스트 종료 시 남은 Timer 가 있으면 프레임워크가 실패시킨다.
  });
}
