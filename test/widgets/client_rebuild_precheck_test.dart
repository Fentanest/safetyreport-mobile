// Client 모드 초기화 사전 확인 — 이미 끝난 서버는 초기화 화면을 거치지 않고 바로 메인으로 넘어간다(SQ-?).
// CommunityRebuildScreen 자체 상태기계는 test/widgets/community_rebuild_screen_test.dart 에서 검증한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/screens/community_rebuild_screen.dart';
import 'package:safetyreport/services/community_server_link_service.dart';

/// 서버 상태를 돌려주는 가짜 Client (community_rebuild_screen_test.dart 와 같은 모양).
class _FakeServerClient extends CommunityServerRebuildClient {
  const _FakeServerClient(this.data);
  final Map<String, dynamic> data;

  @override
  Future<CommunityGateLinkResult> fetch(
    String baseUrl,
    String apiKey,
    String? token,
  ) async => CommunityGateLinkResult.success(data);
}

/// 네트워크 오류 등 확인 자체가 실패하는 경우.
class _ErrorServerClient extends CommunityServerRebuildClient {
  const _ErrorServerClient();

  @override
  Future<CommunityGateLinkResult> fetch(
    String baseUrl,
    String apiKey,
    String? token,
  ) async => CommunityGateLinkResult.failure(
    message: '서버에 연결할 수 없습니다.',
    offline: true,
  );
}

const _rebuildTitle = '초기화 크롤링';

void main() {
  testWidgets(
    'required=false goes straight to main without ever showing rebuild text',
    (tester) async {
      // _PostGateFlow 와 같이 onDone 에서 실제로 화면을 메인으로 바꿔야
      // 확인이 끝난 뒤에도 중립 로딩(인디케이터)이 영원히 남아 pumpAndSettle 이 멈추지 않는다.
      var done = 0;
      var reachedMain = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              if (reachedMain) return const Scaffold(body: Text('메인 화면'));
              return ClientRebuildPreCheck(
                serverBaseUrl: 'https://pc.example',
                serverApiKey: 'key',
                serverClient: const _FakeServerClient({
                  'required': false,
                  'state': 'completed',
                }),
                onDone: () async {
                  done++;
                  setState(() => reachedMain = true);
                },
              );
            },
          ),
        ),
      );
      // 확인이 끝나기 전에도 초기화 문구를 보여주지 않는다 — 중립 로딩만.
      expect(find.text(_rebuildTitle), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(done, 1);
      expect(find.text('메인 화면'), findsOneWidget);
      expect(find.text(_rebuildTitle), findsNothing);
      expect(
        find.textContaining('초기화 크롤링을 한 번 진행해야 합니다'),
        findsNothing,
      );
    },
  );

  testWidgets('required=true shows the rebuild screen', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ClientRebuildPreCheck(
          serverBaseUrl: 'https://pc.example',
          serverApiKey: 'key',
          serverClient: const _FakeServerClient({
            'required': true,
            'state': 'required',
          }),
          onDone: () async => done++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(done, 0);
    expect(find.text(_rebuildTitle), findsOneWidget);
    expect(
      find.textContaining('연결된 서버에서 초기화 크롤링을 진행합니다'),
      findsOneWidget,
    );
  });

  testWidgets('a fetch error shows the rebuild screen', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ClientRebuildPreCheck(
          serverBaseUrl: 'https://pc.example',
          serverApiKey: 'key',
          serverClient: const _ErrorServerClient(),
          onDone: () async => done++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(done, 0);
    expect(find.text(_rebuildTitle), findsOneWidget);
    expect(find.textContaining('서버에 연결할 수 없습니다'), findsOneWidget);
  });
}
