// SQ-P04 — 서버 유지보수 상태 확인은 앱이 백그라운드면 멈추고, 복귀하면 즉시 한 번 확인한 뒤 다시 돈다.
// 결과가 같으면 다시 그리지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as widgets show debugOnRebuildDirtyWidget;
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/maintenance_status_bar.dart';

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

Map<String, dynamic> _running(int done) => {
  'active': true,
  'jobs': [
    {
      'key': 'photo_capture_time',
      'label': '주정차 사진 촬영 시각 읽기',
      'state': 'running',
      'total': 10,
      'done': done,
      'current': '',
      'message': '',
    },
  ],
};

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(bottomNavigationBar: child),
  );

  testWidgets('stops polling in background and checks once on resume', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        MaintenanceStatusBar(
          fetchServerStatus: () async {
            calls++;
            return null;
          },
        ),
      ),
    );
    await tester.pump();
    expect(calls, 1);

    await tester.pump(const Duration(seconds: 30));
    expect(calls, 2, reason: '30s idle schedule while visible');

    _toBackground(tester);
    await tester.pump(const Duration(minutes: 5));
    expect(calls, 2, reason: 'no server polling while in background');

    _toForeground(tester);
    await tester.pump();
    expect(calls, 3, reason: 'immediate check on resume');

    await tester.pump(const Duration(seconds: 30));
    expect(calls, 4, reason: 'schedule resumes after resume');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a fetch in flight when backgrounded does not reschedule', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        MaintenanceStatusBar(
          fetchServerStatus: () async {
            calls++;
            await Future<void>.delayed(const Duration(seconds: 1));
            return _running(calls);
          },
        ),
      ),
    );
    // 첫 요청이 진행 중일 때 백그라운드로 간다.
    _toBackground(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 1, reason: 'no 2s active polling in background');

    _toForeground(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 3, reason: '2s active schedule resumes');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('does not rebuild when the polled state is unchanged', (
    tester,
  ) async {
    var rebuilds = 0;
    final previous = widgets.debugOnRebuildDirtyWidget;
    widgets.debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is MaintenanceStatusBar) rebuilds++;
    };
    addTearDown(() => widgets.debugOnRebuildDirtyWidget = previous);

    var status = _running(3);
    await tester.pumpWidget(
      host(MaintenanceStatusBar(fetchServerStatus: () async => status)),
    );
    await tester.pump();
    expect(find.textContaining('3/10'), findsOneWidget);
    rebuilds = 0;

    // 같은 결과를 세 번 받는다(2초 간격).
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    expect(rebuilds, 0, reason: 'unchanged server state must not setState');

    status = _running(4);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('4/10'), findsOneWidget);
    expect(rebuilds, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('idle (null) status never rebuilds', (tester) async {
    var rebuilds = 0;
    final previous = widgets.debugOnRebuildDirtyWidget;
    widgets.debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is MaintenanceStatusBar) rebuilds++;
    };
    addTearDown(() => widgets.debugOnRebuildDirtyWidget = previous);

    await tester.pumpWidget(
      host(MaintenanceStatusBar(fetchServerStatus: () async => null)),
    );
    await tester.pump();
    rebuilds = 0;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(rebuilds, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
