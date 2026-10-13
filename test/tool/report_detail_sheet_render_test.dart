// 합성 신고 상세 시트 캡처. SR_DETAIL_RENDER_OUT=<PNG 경로>일 때만 실행한다.
// golden 기준을 생성하거나 갱신하지 않는다.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';

import '../support/ui_harness.dart';

void main() {
  final output = Platform.environment['SR_DETAIL_RENDER_OUT'];
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('신고 상세 시트를 실제 Flutter 렌더로 PNG 저장', (tester) async {
    final missingFont = await loadGoldenFonts();
    expect(missingFont, isNull, reason: '한글·아이콘 폰트가 있어야 캡처할 수 있다');
    tester.view.physicalSize = const Size(412, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const boundaryKey = ValueKey('detail-render');
    final report = Report.fromJson({
      'ID': 'fixture-001',
      '신고번호': 'SPP-2610-0000001',
      '신고명': '신호 위반',
      '처리상태': '수용',
      '신고일': '2026-10-01',
      '답변일': '2026-10-12',
      '처리기관': '예시 교통 담당 기관',
      '담당자': '예시 담당자',
      '범칙금_과태료': '과태료: 70,000원',
      '차량번호': '12가3456',
      '위반법규': '도로교통법 제5조',
      '위반장소': '예시시 예시구 예시로 123',
      '발생일자': '2026-10-01',
      '발생시각': '19:09',
      '신고내용': '교차로 신호 위반을 확인했습니다. 검수용 합성 신고입니다.',
      '처리내용': '제출된 자료를 확인하여 처리했습니다. 검수용 합성 답변입니다.',
      'category': 'traffic',
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: Scaffold(
            appBar: AppBar(title: const Text('대시보드')),
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (_) => ReportDetailSheet(report: report),
                  ),
                  child: const Text('상세 열기'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('상세 열기'));
    await tester.pumpAndSettle();
    // 실제 모달을 위로 끌어 펼치되, 내용 스크롤은 맨 위에 둔다.
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('신고내용'), findsOneWidget);
    expect(find.text('처리내용'), findsOneWidget);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        expect(bytes, isNotNull);
        await File(output!).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }, skip: output == null);
}
