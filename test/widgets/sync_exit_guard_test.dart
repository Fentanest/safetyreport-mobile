import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:safetyreport/widgets/sync_exit_guard.dart';

void main() {
  testWidgets('개별 자동 동기화의 서비스가 켜진 동안에도 뒤로 가기 보호 상태다', (tester) async {
    const channel = MethodChannel('com.fentanest.mysafetyreport/permissions');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => true);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    expect(SyncEngine.runningListenable.value, isFalse);
    await SyncEngine.acquireFgs('테스트 동기화');
    expect(SyncEngine.runningListenable.value, isTrue);
    await SyncEngine.releaseFgs();
    expect(SyncEngine.runningListenable.value, isFalse);
  });

  testWidgets('동기화 중 뒤로 가기를 여러 번 눌러도 실행 화면이 닫히지 않는다', (tester) async {
    final running = ValueNotifier(true);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('대시보드')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => SyncExitGuard(
          running: running,
          child: const Scaffold(body: Text('동기화 화면')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('동기화 화면'), findsOneWidget);

    running.value = false;
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('동기화 화면'), findsNothing);
    expect(find.text('대시보드'), findsOneWidget);
    running.dispose();
  });
}
