import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:video_player/video_player.dart';

Report _reportWithVideos() => Report(
  id: 'v1',
  reportNumber: 'SPP-2604-0000001',
  name: '동영상 신고',
  date: '2026-04-23',
  responseDate: '2026-04-24',
  agency: '테스트 기관',
  manager: '담당자',
  status: '수용',
  result: '수용',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '12가3456',
  law: '',
  location: '서울',
  occurrenceDate: '2026-04-23',
  occurrenceTime: '17:45',
  reportContent: '신고 내용',
  processContent: '처리 내용',
  attachedFiles: 'https://example.invalid/a.mp4\nhttps://example.invalid/b.mp4',
  category: 'traffic',
);

void main() {
  // 2026-09-24 제보: 시트를 열면 동영상을 모두 자동으로 불러와, 위로 스크롤하는 도중 로딩이 끝나면
  // 스크롤이 멈췄다. 이제는 탭해야 불러온다 — 스크롤만으로는 플레이어를 만들지 않는다.
  testWidgets('첨부 동영상은 탭하기 전에는 불러오지 않는다', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(Brightness.light),
        home: Scaffold(body: ReportDetailSheet(report: _reportWithVideos())),
      ),
    );
    await tester.pump();

    final placeholder = find.text('탭하여 동영상 불러오기');
    Future<void> scrollToVideos() async {
      for (
        var i = 0;
        i < 20 && placeholder.hitTestable().evaluate().length < 2;
        i++
      ) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -250));
        await tester.pumpAndSettle();
      }
    }

    await scrollToVideos();
    // 위아래로 스크롤해도 아무것도 불러오지 않는다.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    await scrollToVideos();
    expect(placeholder.hitTestable(), findsNWidgets(2));
    expect(find.byType(VideoPlayer), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 탭한 동영상만 불러오기 시작한다(테스트 환경엔 플레이어 구현이 없어 로딩 또는 재시도 상태가 된다).
    await tester.tap(placeholder.hitTestable().first);
    await tester.pump();
    expect(placeholder, findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator).evaluate().length +
          find.text('재시도').evaluate().length,
      1,
    );
  });
}
