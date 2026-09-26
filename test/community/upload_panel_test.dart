// 지도 탭 패널 위젯 테스트 (가짜 데이터 — 네트워크 없음).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/widgets/community_upload_panel.dart';

CommunityPanelData data({
  bool client = false,
  int pending = 0,
  int blocked = 0,
  int dead = 0,
  int reshare = 0,
  String? projection,
}) =>
    CommunityPanelData(
      clientMode: client,
      pending: pending,
      blocked: blocked,
      deadLetter: dead,
      reshareCandidates: reshare,
      lastProjection: projection,
    );

Future<void> pumpPanel(WidgetTester tester, CommunityPanelData d) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
        body: SingleChildScrollView(
            child: CommunityUploadPanel(
                data: d, onUploadNow: () {}, onReshare: () {}))),
  ));
  await tester.pumpAndSettle();
  // 접이식 카드를 펼친다.
  await tester.tap(find.byType(ExpansionTile).first);
  await tester.pumpAndSettle();
}

void main() {
  group('CommunityUploadPanel', () {
    testWidgets('전송 대기 건수와 투영 문구', (tester) async {
      await pumpPanel(
          tester, data(pending: 3, projection: 'published'));
      expect(find.text('전송 대기 3건'), findsWidgets);
      expect(find.text('최근: 지도 반영됨'), findsOneWidget);
      expect(find.text('지금 업로드'), findsOneWidget);
    });

    testWidgets('보류·전송 불가 표시', (tester) async {
      await pumpPanel(tester, data(blocked: 2, dead: 1));
      expect(find.text('보류 2건(사유 확인 필요)'), findsOneWidget);
      expect(find.text('전송 불가 1건'), findsOneWidget);
    });

    testWidgets('reshare 버튼은 후보 있을 때만', (tester) async {
      await pumpPanel(tester, data(reshare: 0));
      expect(find.textContaining('다시 공유'), findsNothing);
      await pumpPanel(tester, data(reshare: 5));
      expect(find.text('이전 수집 사본 다시 공유(5건)'), findsOneWidget);
    });

    testWidgets('Client 모드 문구', (tester) async {
      await pumpPanel(tester, data(client: true));
      expect(find.text('공유 업로드(서버)'), findsOneWidget);
      expect(find.text('업로드는 연결된 서버가 수행합니다'), findsOneWidget);
      expect(find.text('지금 업로드'), findsNothing);
    });

    testWidgets('라이트·다크 모두 빌드', (tester) async {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        await tester.pumpWidget(MaterialApp(
          themeMode: mode,
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: CommunityUploadPanel(
                      data: data(pending: 1),
                      onUploadNow: () {},
                      onReshare: () {}))),
        ));
        await tester.pumpAndSettle();
        expect(find.byType(CommunityUploadPanel), findsOneWidget);
      }
    });
  });
}
