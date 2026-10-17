// SQ-B13: Standalone 초기화 게이트는 "건너뛰기(onDone)"를 build 마다 예약하지 않고 한 번만, 살아 있을 때만 부른다.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:safetyreport/screens/rebuild_prepare_failure_screen.dart';
import 'package:safetyreport/services/db_failure.dart';

void main() {
  Future<int Function()> pumpGate(
    WidgetTester tester,
    Future<Never> Function()? failing,
  ) async {
    var calls = 0;
    late StateSetter rebuildParent;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuildParent = setState;
            return StandaloneRebuildGate(
              prepare: failing ?? () async => null,
              onDone: () => calls++,
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // 부모가 여러 번 다시 그려도(게이트를 치우지 않은 채) 추가로 부르지 않는다.
    for (var i = 0; i < 3; i++) {
      rebuildParent(() {});
      await tester.pump();
    }
    return () => calls;
  }

  testWidgets('no rebuild needed: onDone fires exactly once', (tester) async {
    final calls = await pumpGate(tester, null);
    expect(calls(), 1);
  });

  testWidgets('store error: stays with a retry button', (tester) async {
    final calls = await pumpGate(
      tester,
      () async => throw StateError('store unavailable'),
    );
    expect(calls(), 0);
    expect(find.byKey(const Key('rebuildPrepareRetry')), findsOneWidget);
    expect(find.textContaining('필요한지 확인하지 못했습니다'), findsOneWidget);
  });

  testWidgets('retry reruns preparation once and only skips after success', (
    tester,
  ) async {
    var attempts = 0;
    var done = 0;
    final pending = Completer<CommunityRebuild?>();
    await tester.pumpWidget(
      MaterialApp(
        home: StandaloneRebuildGate(
          prepare: () {
            attempts++;
            if (attempts == 1) throw StateError('scope unavailable');
            return pending.future;
          },
          onDone: () => done++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(done, 0);
    await tester.tap(find.byKey(const Key('rebuildPrepareRetry')));
    await tester.pump();
    expect(attempts, 2);
    expect(done, 0);
    expect(find.byKey(const Key('rebuildPrepareRetry')), findsNothing);
    pending.complete(null);
    await tester.pump();
    await tester.pump();
    expect(done, 1);
  });

  // 2026-10-17 제보(판정 실패 화면에서 막힘, 캐시 삭제 뒤 정상): 원인별 자동 복구·들어가기·종료·오류 내용.
  testWidgets('DB lock: waits and re-decides once by itself', (tester) async {
    var attempts = 0;
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StandaloneRebuildGate(
          lockRetryDelay: Duration.zero,
          prepare: () async {
            attempts++;
            if (attempts == 1) throw Exception('database is locked');
            return null;
          },
          onDone: () => done++,
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(attempts, 2);
    expect(done, 1);
    expect(find.byType(RebuildPrepareFailureScreen), findsNothing);
  });

  testWidgets('storage full: cleans the cache, explains, and can enter', (
    tester,
  ) async {
    var attempts = 0;
    var cleanups = 0;
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StandaloneRebuildGate(
          cleanup: () async => cleanups++,
          prepare: () async {
            attempts++;
            throw Exception('SqliteException(13): database or disk is full');
          },
          onDone: () => done++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(cleanups, 1);
    expect(
      find.text(
        RebuildPrepareFailureScreen.messageFor(DbFailureKind.storageFull),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('rebuildPrepareExit')), findsNothing);
    expect(find.textContaining('disk is full'), findsOneWidget);

    // 다시 시도는 캐시를 한 번 더 정리한 뒤 판정한다(자동 재판정 포함 두 번).
    await tester.tap(find.byKey(const Key('rebuildPrepareRetry')));
    await tester.pumpAndSettle();
    expect(cleanups, 3);
    expect(attempts, 4);
    expect(done, 0);

    await tester.tap(find.byKey(const Key('rebuildPrepareEnter')));
    await tester.pump();
    expect(done, 1);
  });

  testWidgets('unknown failure: shows the error and can exit the app', (
    tester,
  ) async {
    var exits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StandaloneRebuildGate(
          exitApp: () async => exits++,
          prepare: () async => throw StateError('store unavailable'),
          onDone: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('필요한지 확인하지 못했습니다'), findsOneWidget);
    expect(find.textContaining('StateError'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('rebuildPrepareExit')));
    await tester.tap(find.byKey(const Key('rebuildPrepareExit')));
    await tester.pump();
    expect(exits, 1);
  });
}
