import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/theme/sr_colors.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:video_player/video_player.dart';

/// WP4 상세 시트: SQ-U12(라벨 폭) · SQ-U13(상태 칩 대비) · SQ-U14(동영상 방향 복원) · SQ-U20(툴팁·터치 영역).

Report _report({
  String status = '일부수용',
  String fineInfo = '과태료 40,000원',
  String attachedFiles = '',
  bool withLinks = true,
}) => Report(
  id: 'wp4',
  reportNumber: 'SPP-2610-0000001',
  name: '상세 시트 검수 신고',
  date: '2026-04-23',
  responseDate: '2026-04-24',
  agency: '예시 교통 담당 기관',
  manager: withLinks ? '담당자' : '',
  status: status,
  result: '',
  fineInfo: fineInfo,
  penaltyPoints: '',
  carNumber: withLinks ? '12가3456' : '',
  law: withLinks ? '도로교통법' : '',
  location: withLinks ? '서울' : '',
  occurrenceDate: '2026-04-23',
  occurrenceTime: '17:45',
  reportContent: '',
  processContent: '',
  attachedFiles: attachedFiles,
  category: 'traffic',
);

Future<List<FlutterErrorDetails>> _pumpSheet(
  WidgetTester tester,
  Report report, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  double width = 360,
  double height = 800,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: ReportDetailSheet(report: report)),
      ),
    );
    await tester.pump();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

/// 글자 색과, 글자를 감싼 가장 가까운 칠한 상자(배지 배경)의 대비.
double _chipContrast(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final fg = paragraph.text.style!.color!;
  final box = tester
      .widgetList<DecoratedBox>(
        find.ancestor(of: text, matching: find.byType(DecoratedBox)),
      )
      .map((d) => d.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.color != null);
  final surface = Theme.of(tester.element(text)).colorScheme.surface;
  return contrastRatio(fg, Color.alphaBlend(box.color!, surface));
}

class _FakeController extends VideoPlayerController {
  _FakeController(super.url) : super.networkUrl();

  @override
  Future<void> initialize() async {}
}

void main() {
  group('SQ-U12 상세 라벨 폭', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('360dp · 글자 $scale배: "과태료/범칙금" 이 값과 붙거나 꺾이지 않는다', (
        tester,
      ) async {
        final errors = await _pumpSheet(
          tester,
          _report(),
          textScale: scale,
          height: 2000,
        );
        expect(errors, isEmpty, reason: errors.map((e) => e.summary).join());

        final label = tester.getRect(find.text('과태료/범칙금'));
        final value = tester.getRect(find.text('과태료 40,000원'));
        final oneLine = 13 * scale * 1.6;
        expect(label.height, lessThan(oneLine), reason: '라벨은 한 줄이어야 한다');
        final sideBySide = value.left - label.right >= 8;
        final stacked = value.top >= label.bottom;
        expect(
          sideBySide || stacked,
          isTrue,
          reason: '라벨 $label · 값 $value 사이에 간격이 없다',
        );
        // 다른 라벨도 같은 열 폭을 쓴다(값 시작 위치가 같다).
        if (sideBySide) {
          final other = tester.getRect(find.text('2026-04-23  17:45'));
          expect(other.left, value.left);
        }
      });
    }
  });

  group('SQ-U13 상세 시트 상태 칩 대비', () {
    for (final brightness in Brightness.values) {
      for (final status in ['일부수용', '수용', '처리중', '보완요청', '불수용']) {
        testWidgets('${brightness.name} · $status ≥ 4.5:1', (tester) async {
          await _pumpSheet(
            tester,
            _report(status: status),
            brightness: brightness,
          );
          expect(
            _chipContrast(tester, find.text(status)),
            greaterThanOrEqualTo(4.5),
          );
        });
      }
    }
  });

  group('SQ-U14·U20 동영상', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });
      ReportDetailSheet.videoControllerFactory = _FakeController.new;
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      ReportDetailSheet.videoControllerFactory =
          VideoPlayerController.networkUrl;
    });

    Future<void> loadVideo(WidgetTester tester) async {
      // 대기열 꼬리는 이 테스트의 (가짜 시간) 영역에서 새로 만든다.
      ReportDetailSheet.resetVideoLoadQueue();
      await _pumpSheet(
        tester,
        _report(
          attachedFiles: 'https://example.invalid/a.mp4',
          withLinks: false,
          fineInfo: '',
        ),
        height: 1600,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      // 불러오기가 끝나면 조작 막대(현재 위치·길이)가 보인다.
      expect(find.text('00:00'), findsNWidgets(2));
    }

    List<Object?> orientations() => calls
        .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .map((c) => c.arguments)
        .toList();

    testWidgets('전체화면을 닫으면 방향 고정을 풀고(시스템 기본) 세로로 묶지 않는다', (tester) async {
      await loadVideo(tester);
      await tester.tap(find.byTooltip('전체화면'));
      await tester.pumpAndSettle();
      expect(orientations().last, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);

      await tester.tap(find.byTooltip('전체화면 닫기'));
      await tester.pumpAndSettle();
      expect(orientations().last, isEmpty);
      expect(
        orientations().any(
          (a) =>
              a is List &&
              a.length == 1 &&
              a.single == 'DeviceOrientation.portraitUp',
        ),
        isFalse,
      );
    });

    testWidgets('전체화면 조작 막대는 시스템 바·노치 여백 안에 있다', (tester) async {
      tester.view.padding = const FakeViewPadding(left: 40, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(left: 40, bottom: 24);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await loadVideo(tester);
      await tester.tap(find.byTooltip('전체화면'));
      await tester.pumpAndSettle();
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final play = tester.getRect(find.byTooltip('재생'));
      final close = tester.getRect(find.byTooltip('전체화면 닫기'));
      expect(play.left, greaterThanOrEqualTo(40));
      expect(close.bottom, lessThanOrEqualTo(size.height - 24));
    });

    testWidgets('동영상 버튼은 툴팁이 있고 터치 영역이 48dp 이상이다', (tester) async {
      final semantics = tester.ensureSemantics();
      await loadVideo(tester);
      for (final tip in ['재생', '전체화면']) {
        final size = tester.getSize(find.byTooltip(tip));
        expect(size.width, greaterThanOrEqualTo(48), reason: tip);
        expect(size.height, greaterThanOrEqualTo(48), reason: tip);
      }
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

      await tester.tap(find.byTooltip('전체화면'));
      await tester.pumpAndSettle();
      for (final tip in ['재생', '전체화면 닫기']) {
        final size = tester.getSize(find.byTooltip(tip));
        expect(size.width, greaterThanOrEqualTo(48), reason: tip);
        expect(size.height, greaterThanOrEqualTo(48), reason: tip);
      }
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
    });
  });
}
