import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_list_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/selection_action_bar.dart';
import 'package:safetyreport/widgets/selection_back_scope.dart';

/// 선택 상태를 들고 SelectionBackScope 로 감싼 최소 화면.
class _SelectableBody extends StatefulWidget {
  const _SelectableBody();

  @override
  State<_SelectableBody> createState() => _SelectableBodyState();
}

class _SelectableBodyState extends State<_SelectableBody> {
  bool selected = true;

  @override
  Widget build(BuildContext context) {
    return SelectionBackScope(
      selectionMode: selected,
      onCancel: () => setState(() => selected = false),
      child: Scaffold(body: Text(selected ? '선택 중' : '선택 없음')),
    );
  }
}

Report _report(String number) => Report(
  id: number,
  reportNumber: number,
  name: '테스트 신고 $number',
  date: '2026-08-14',
  responseDate: '2026-08-14',
  agency: '테스트 기관',
  manager: '담당자',
  status: '수용',
  result: '답변완료',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '도로교통법',
  location: '서울',
  occurrenceDate: '2026-08-13',
  occurrenceTime: '12:00',
  reportContent: '신고 내용',
  processContent: '처리 내용',
  category: 'traffic',
);

class _FixedReportProvider extends ReportProvider {
  final List<Report> traffic = [_report('SPP-2608-0000001')];

  @override
  List<Report> get filteredTrafficReports => traffic;

  @override
  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {}

  @override
  Future<void> fetchDuplicateReports() async {}
}

void main() {
  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  bool exitedApp() =>
      platformCalls.any((c) => c.method == 'SystemNavigator.pop');

  testWidgets('루트 화면: 선택 중 뒤로가기는 앱 종료 대신 선택만 취소한다', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _SelectableBody()));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('선택 없음'), findsOneWidget);
    expect(exitedApp(), isFalse);

    // 선택이 없으면 원래대로 앱을 닫는다.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(exitedApp(), isTrue);
  });

  testWidgets('push 된 화면: 첫 뒤로가기는 선택 취소, 다음 뒤로가기는 화면 닫기', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('이전 화면')),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const _SelectableBody()),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('선택 없음'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('이전 화면'), findsOneWidget);
    expect(exitedApp(), isFalse);
  });

  testWidgets('숨은 탭(TickerMode false)의 선택은 뒤로가기를 가로채지 않는다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TickerMode(enabled: false, child: _SelectableBody()),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('선택 중'), findsOneWidget);
    expect(exitedApp(), isTrue);
  });

  testWidgets('신고 내역: 길게 눌러 선택한 뒤 뒤로가기로 선택 모드가 풀린다', (tester) async {
    final provider = _FixedReportProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: AppTheme.build(Brightness.light),
          home: const ReportListScreen(),
        ),
      ),
    );
    await tester.pump();

    await tester.longPress(find.text('테스트 신고 SPP-2608-0000001'));
    await tester.pump();
    expect(find.byType(SelectionActionBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('선택 취소'),
      ),
      findsOneWidget,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(SelectionActionBar), findsNothing);
    expect(find.text('1개 선택됨'), findsNothing);
    expect(find.text('신고 내역'), findsOneWidget);
    expect(exitedApp(), isFalse);
  });
}
