import 'dart:async';

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

/// 플랫폼 없이 불러오기 완료 시점을 테스트가 정한다.
class _FakeController extends VideoPlayerController {
  _FakeController(super.url) : super.networkUrl();
  final done = Completer<void>();

  @override
  Future<void> initialize() => done.future;
}

void main() {
  late List<_FakeController> created;

  setUp(() {
    created = [];
    ReportDetailSheet.videoControllerFactory = (url) {
      final c = _FakeController(url);
      created.add(c);
      return c;
    };
  });

  tearDown(() {
    ReportDetailSheet.videoControllerFactory = VideoPlayerController.networkUrl;
  });

  // 2026-09-24 제보: 시트를 열면 동영상을 모두 한꺼번에 불러와, 위로 스크롤하는 도중 로딩이 끝나면
  // 스크롤이 멈췄다. 이제는 자동으로 불러오되 (1) 스크롤 중엔 시작하지 않고 (2) 하나씩 불러오며
  // (3) 로딩이 끝나도 칸 높이가 바뀌지 않는다.
  testWidgets('첨부 동영상은 보이고 스크롤이 멈췄을 때 하나씩 자동으로 불러온다', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(Brightness.light),
        home: Scaffold(body: ReportDetailSheet(report: _reportWithVideos())),
      ),
    );
    await tester.pumpAndSettle();
    expect(created, isEmpty, reason: '화면 밖 동영상은 불러오지 않는다');

    final scrollable = find.byType(Scrollable).first;
    final placeholder = find.byIcon(Icons.play_circle_outline);

    // 손가락을 떼지 않은 채 맨 아래(동영상 칸)까지 끌어올리는 동안에는 시작하지 않는다.
    final position = tester.state<ScrollableState>(scrollable).position;
    final gesture = await tester.startGesture(tester.getCenter(scrollable));
    for (var i = 0; i < 40 && position.pixels < position.maxScrollExtent; i++) {
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(placeholder, findsNWidgets(2));
    expect(created, isEmpty, reason: '스크롤 중에는 불러오기를 시작하지 않는다');

    await gesture.up();
    // 로딩 스피너는 끝없이 돌아서 pumpAndSettle 대신 시간을 흘린다(관성 스크롤 정지 + 다음 프레임).
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final extentBefore = position.maxScrollExtent;

    // 멈추면 첫 동영상만 불러오고, 두 번째는 첫 번째가 끝날 때까지 기다린다.
    expect(created, hasLength(1));
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));

    created.first.done.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(created, hasLength(2));
    expect(
      position.maxScrollExtent,
      extentBefore,
      reason: '로딩이 끝나도 동영상 칸 높이가 바뀌지 않는다',
    );

    created.last.done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(VideoPlayer), findsNWidgets(2));
    expect(position.maxScrollExtent, extentBefore);
  });
}
