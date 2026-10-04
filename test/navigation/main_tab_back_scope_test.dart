// SQ-U05: 하단 탭 뒤로 가기와 선택 모드 해제(SelectionBackScope)·동기화 중 종료 막기(SyncExitGuard)의 순서.
// ① 보이는 탭의 선택 취소 ② 비0 탭 → 대시보드 ③ 대시보드에서 동기화 중이면 안내 ④ 종료.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/navigation/main_tabs.dart';
import 'package:safetyreport/widgets/selection_back_scope.dart';

const _syncSnack = '동기화 중에는 앱을 종료할 수 없습니다. 중지 버튼으로 동기화를 멈춰 주세요.';

class _Tab extends StatefulWidget {
  const _Tab(this.label, {super.key});
  final String label;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool selecting = false;

  void startSelecting() => setState(() => selecting = true);

  @override
  Widget build(BuildContext context) => SelectionBackScope(
    selectionMode: selecting,
    onCancel: () => setState(() => selecting = false),
    child: Center(child: Text('${widget.label}${selecting ? ' 선택 중' : ''}')),
  );
}

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.running, required this.tabKeys});
  final ValueNotifier<bool> running;
  final List<GlobalKey<_TabState>> tabKeys;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  int index = 0;

  void select(int i) => setState(() => index = i);

  @override
  Widget build(BuildContext context) => MainTabBackScope(
    currentIndex: index,
    onReturnHome: () => select(MainTabs.dashboard),
    running: widget.running,
    child: Scaffold(
      body: IndexedStack(
        index: index,
        children: [
          for (var i = 0; i < MainTabs.count; i++)
            TickerMode(
              enabled: i == index,
              child: _Tab('탭$i', key: widget.tabKeys[i]),
            ),
        ],
      ),
    ),
  );
}

void main() {
  late List<MethodCall> platformCalls;
  late ValueNotifier<bool> running;
  late List<GlobalKey<_TabState>> tabKeys;
  final harnessKey = GlobalKey<_HarnessState>();
  final navKey = GlobalKey<NavigatorState>();

  setUp(() {
    platformCalls = [];
    running = ValueNotifier(false);
    tabKeys = [for (var i = 0; i < MainTabs.count; i++) GlobalKey<_TabState>()];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    running.dispose();
  });

  bool exited() => platformCalls.any((c) => c.method == 'SystemNavigator.pop');
  int index() => harnessKey.currentState!.index;

  Future<void> pumpHarness(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: _Harness(key: harnessKey, running: running, tabKeys: tabKeys),
      ),
    );
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
  }

  void startSelecting(int tab) => tabKeys[tab].currentState!.startSelecting();

  testWidgets('non-dashboard tab: back → dashboard, then exit', (tester) async {
    await pumpHarness(tester);
    harnessKey.currentState!.select(MainTabs.notifications);
    await tester.pump();

    await back(tester);
    expect(index(), MainTabs.dashboard);
    expect(exited(), isFalse);

    await back(tester);
    expect(exited(), isTrue);
  });

  testWidgets(
    'selection mode on a tab: back clears selection first, then dashboard, then exit',
    (tester) async {
      await pumpHarness(tester);
      harnessKey.currentState!.select(MainTabs.reports);
      await tester.pump();
      startSelecting(MainTabs.reports);
      await tester.pump();
      expect(find.text('탭1 선택 중'), findsOneWidget);

      await back(tester);
      expect(find.text('탭1 선택 중'), findsNothing);
      expect(index(), MainTabs.reports, reason: '선택 취소만 하고 탭은 그대로');

      await back(tester);
      expect(index(), MainTabs.dashboard);
      expect(exited(), isFalse);

      await back(tester);
      expect(exited(), isTrue);
    },
  );

  testWidgets('selection on the dashboard: back clears it before exiting', (
    tester,
  ) async {
    await pumpHarness(tester);
    startSelecting(MainTabs.dashboard);
    await tester.pump();

    await back(tester);
    expect(find.text('탭0 선택 중'), findsNothing);
    expect(exited(), isFalse);

    await back(tester);
    expect(exited(), isTrue);
  });

  testWidgets('a hidden tab selection does not intercept back on another tab', (
    tester,
  ) async {
    await pumpHarness(tester);
    harnessKey.currentState!.select(MainTabs.reports);
    await tester.pump();
    startSelecting(MainTabs.reports);
    await tester.pump();
    harnessKey.currentState!.select(MainTabs.statistics);
    await tester.pump();

    await back(tester);
    expect(index(), MainTabs.dashboard, reason: '숨은 탭의 선택은 뒤로 가기를 가로채지 않는다');
    expect(exited(), isFalse);
  });

  testWidgets(
    'sync running: back on a tab goes to dashboard without the exit notice',
    (tester) async {
      running.value = true;
      await pumpHarness(tester);
      harnessKey.currentState!.select(MainTabs.statistics);
      await tester.pump();

      await back(tester);
      expect(index(), MainTabs.dashboard);
      expect(find.text(_syncSnack), findsNothing, reason: '탭 이동은 종료 시도가 아니다');

      await back(tester);
      expect(exited(), isFalse, reason: '동기화 중 대시보드에서도 종료하지 않는다');
      expect(find.text(_syncSnack), findsOneWidget);

      running.value = false;
      await tester.pump();
      await back(tester);
      expect(exited(), isTrue);
    },
  );

  testWidgets('sync running + selection: back only clears the selection', (
    tester,
  ) async {
    running.value = true;
    await pumpHarness(tester);
    startSelecting(MainTabs.dashboard);
    await tester.pump();

    await back(tester);
    expect(find.text('탭0 선택 중'), findsNothing);
    expect(find.text(_syncSnack), findsNothing);
    expect(exited(), isFalse);
  });

  testWidgets('pushed route pops normally and keeps the current tab', (
    tester,
  ) async {
    await pumpHarness(tester);
    harnessKey.currentState!.select(MainTabs.management);
    await tester.pump();
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('위 화면')),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('위 화면'), findsNothing);
    expect(index(), MainTabs.management);
    expect(exited(), isFalse);
  });
}
