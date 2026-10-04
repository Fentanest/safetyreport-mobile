// SQ-U15·SQ-U04(대시보드)·SQ-U22: 대시보드 처리 상태 요약이 첫 화면을 덜 차지하고,
// 0건 칸도 같은 배치(흐리게·누를 수 없음)를 유지하며, 큰 글꼴(1.3·2.0배)에서도 넘치지 않고,
// 건수는 쉼표 표기를 쓰는지, 감시 목록은 대시보드에서 3건까지 한 줄로만 보이는지 고정한다.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/dashboard_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/sync_status_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/ui_harness.dart';

class _DashProvider extends ReportProvider {
  _DashProvider(this._fake, {this.mode = AppMode.server, this.demo = false});
  final DashboardStats _fake;
  final AppMode mode;
  final bool demo;

  @override
  AppMode get appMode => mode;

  @override
  bool get isStandaloneDemo => demo;

  @override
  DashboardStats? get stats => _fake;

  @override
  bool get isLoading => false;

  @override
  Future<void> fetchSummary() async {}

  @override
  Future<void> refreshSummaryAndRecentAnswers() async {}

  @override
  List<Report> get recentAnswerReports => const [];
}

Report _watched(int i) => Report(
  id: 'w$i',
  reportNumber: 'SPP-2609-00000$i',
  name: '감시 신고 $i — 어린이보호구역 중앙선 침범 역주행 및 신호위반 후 보행자 보호의무 불이행',
  date: '2026-09-2$i',
  responseDate: '',
  agency: '경기도남부경찰청 부천원미경찰서 교통안전과',
  manager: '홍길동',
  status: i.isEven ? '처리중' : '불수용',
  result: '',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '서울31바5845',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
);

DashboardStats _stats({int watchCount = 5, int? watchTotal = 12}) =>
    DashboardStats(
      lastCrawlTime: '',
      total: 12345,
      acceptCount: 8000,
      partialCount: 1200,
      rejectCount: 2690,
      supplementCount: 0,
      processingCount: 455,
      completedCount: 11890,
      withdrawCount: 0,
      withdrawRawCount: 0,
      withdrawGraphCount: 0,
      tFineCount: 4321,
      tPenaltyCount: 2100,
      tRejectCount: 2690,
      tUnconfirmedCount: 0,
      recentAnswers: const [],
      watchlist: [for (var i = 0; i < watchCount; i++) _watched(i)],
      watchlistTotal: watchTotal,
    );

Future<List<FlutterErrorDetails>> _pump(
  WidgetTester tester, {
  required Brightness brightness,
  double textScale = 1.0,
  double width = 360,
  double height = 800,
  DashboardStats? stats,
  AppMode mode = AppMode.server,
  bool demo = false,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final provider = _DashProvider(stats ?? _stats(), mode: mode, demo: demo);
  addTearDown(provider.dispose);

  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const DashboardScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

const _statusLabels = ['보완 요청', '처리 중', '수용', '일부수용', '불수용/기타', '취하'];

final _watchRows = find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('dashboard-watch-row:'),
);

Finder _tile(String label) => find.byKey(ValueKey('dashboard-status-$label'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    for (final scale in uiTextScales) {
      testWidgets('360dp ${brightness.name} 글꼴 $scale배에서 대시보드가 넘치지 않는다', (
        tester,
      ) async {
        final errors = await _pump(
          tester,
          brightness: brightness,
          textScale: scale,
        );
        expect(errors, isEmpty, reason: describeErrors(errors));
        expect(_tile('전체'), findsOneWidget);
        for (final label in _statusLabels) {
          expect(_tile(label), findsOneWidget, reason: label);
        }
      });
    }
  }

  testWidgets('처리 상태 요약이 첫 화면 절반 안에 들어가 동기화 상태 카드가 바로 보인다', (tester) async {
    final errors = await _pump(tester, brightness: Brightness.light);
    expect(errors, isEmpty, reason: describeErrors(errors));
    // 이전 2열·비율 1.65 그리드(카드 7개, 4줄)에서는 동기화 카드가 약 y=500 아래에서 시작했다.
    final syncTop = tester.getTopLeft(find.byType(SyncStatusCard)).dy;
    expect(syncTop, lessThan(400));
    // 상태 6종은 같은 높이의 2줄(3열)로 놓인다 — 취하 칸이 혼자 한 줄을 차지하지 않는다.
    final rows = {
      for (final label in _statusLabels)
        tester.getTopLeft(_tile(label)).dy.roundToDouble(),
    };
    expect(rows.length, 2);
  });

  testWidgets('건수는 쉼표 표기를 쓴다', (tester) async {
    await _pump(tester, brightness: Brightness.light);
    expect(
      find.descendant(of: _tile('전체'), matching: find.text('12,345건')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _tile('수용'), matching: find.text('8,000건')),
      findsOneWidget,
    );
    expect(find.text('4,321'), findsOneWidget); // 교통위반 과태료
    expect(find.textContaining('12345'), findsNothing);
    expect(find.textContaining('8000건'), findsNothing);
  });

  testWidgets('0건 칸은 같은 배치를 유지하되 누를 수 없고, 화살표 자리가 칸마다 같다', (tester) async {
    await _pump(tester, brightness: Brightness.dark);
    double chevronInset(String label) {
      final tile = tester.getRect(_tile(label));
      final chevron = tester.getRect(
        find.descendant(
          of: _tile(label),
          matching: find.byIcon(Icons.chevron_right),
        ),
      );
      return tile.right - chevron.right;
    }

    final insets = {
      for (final label in _statusLabels) chevronInset(label).roundToDouble(),
    };
    expect(insets.length, 1, reason: '화살표 위치가 칸마다 다르다: $insets');

    InkWell inkOf(String label) => tester.widget<InkWell>(
      find.descendant(of: _tile(label), matching: find.byType(InkWell)).first,
    );
    expect(inkOf('보완 요청').onTap, isNull);
    expect(inkOf('취하').onTap, isNull);
    expect(inkOf('수용').onTap, isNotNull);
    expect(inkOf('전체').onTap, isNotNull);

    // 0건 칸 화살표는 보이지 않는다(자리만 차지).
    final zeroChevron = find.descendant(
      of: _tile('보완 요청'),
      matching: find.byIcon(Icons.chevron_right),
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: zeroChevron, matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 0);

    // 같은 줄 칸들은 높이가 같다.
    final heights = {
      for (final label in _statusLabels.take(3))
        tester.getSize(_tile(label)).height.roundToDouble(),
    };
    expect(heights.length, 1);
  });

  testWidgets('감시 목록은 대시보드에서 3건까지 한 줄 요약으로 보이고 나머지는 더 보기로 넘긴다', (tester) async {
    await _pump(tester, brightness: Brightness.light, height: 2400);
    final rows = _watchRows;
    expect(rows, findsNWidgets(3));
    for (final element in rows.evaluate()) {
      final titles = find.descendant(
        of: find.byWidget(element.widget),
        matching: find.byType(Text),
      );
      final title = tester.widget<Text>(titles.first);
      expect(title.maxLines, 1);
    }
    expect(find.text('+ 9건 더 보기'), findsOneWidget);
    expect(find.textContaining('전체 12건'), findsOneWidget);
    // 상세 메타(신고번호·처리기관 줄)는 대시보드 미리보기에 펼치지 않는다 — 상세 시트에서 본다.
    expect(find.text('처리기관 '), findsNothing);
  });

  testWidgets('감시 목록이 3건 이하이면 더 보기를 띄우지 않는다', (tester) async {
    await _pump(
      tester,
      brightness: Brightness.light,
      height: 2400,
      stats: _stats(watchCount: 2, watchTotal: 2),
    );
    expect(_watchRows, findsNWidgets(2));
    expect(find.textContaining('더 보기'), findsNothing);
  });

  testWidgets('동기화 상태 설명은 카드 폭을 다 써서 360dp·1.0배에서 한 줄로 보인다', (tester) async {
    // 줄바꿈 위치는 실제 한글 글꼴 폭에 달려 있어 골든용 글꼴이 있을 때만 확인한다.
    final skip = await tester.runAsync(loadGoldenFonts);
    if (skip != null) {
      markTestSkipped(skip);
      return;
    }
    final errors = await _pump(
      tester,
      brightness: Brightness.light,
      mode: AppMode.standalone,
      demo: true,
    );
    expect(errors, isEmpty, reason: describeErrors(errors));
    final desc = find.text('데모 모드에서는 동기화를 실행할 수 없습니다');
    // 이동 버튼이 설명 오른쪽에 있으면 폭이 모자라 "없습/니다"처럼 꺾였다.
    expect(tester.getSize(desc).height, lessThan(24));
    final action = find.text('동기화 화면');
    expect(tester.getTopLeft(action).dy, lessThan(tester.getTopLeft(desc).dy));
  });

  testWidgets('글꼴 2.0배에서는 동기화 화면 이동 버튼이 설명 아래로 내려가 잘리지 않는다', (tester) async {
    final errors = await _pump(
      tester,
      brightness: Brightness.dark,
      textScale: 2,
      mode: AppMode.standalone,
      demo: true,
    );
    expect(errors, isEmpty, reason: describeErrors(errors));
    final desc = find.text('데모 모드에서는 동기화를 실행할 수 없습니다');
    final action = find.text('동기화 화면');
    expect(
      tester.getTopLeft(action).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(desc).dy),
    );
    // 말줄임(…)으로 잘리지 않았다.
    expect(
      tester.renderObject<RenderParagraph>(action).didExceedMaxLines,
      isFalse,
    );
  });
}
