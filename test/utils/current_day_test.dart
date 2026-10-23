import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/utils/current_day.dart';

void main() {
  testWidgets('여러 구독자는 자정 타이머 하나를 공유하고 마지막 해제 때 정리한다', (tester) async {
    var now = DateTime(2026, 10, 23, 23, 59, 58);
    var clockReads = 0;
    final day = CurrentDay(
      now: () {
        clockReads++;
        return now;
      },
    );
    addTearDown(day.dispose);
    var firstCalls = 0, secondCalls = 0;
    void first() => firstCalls++;
    void second() => secondCalls++;
    day.addListener(first);
    day.addListener(second);
    day.removeListener(first);
    final beforeMidnight = clockReads;
    now = DateTime(2026, 10, 24);
    await tester.pump(const Duration(seconds: 2));
    expect(day.value, DateTime(2026, 10, 24));
    expect(firstCalls, 0);
    expect(secondCalls, 1);
    expect(clockReads, beforeMidnight + 1, reason: '자정 타이머는 한 번만 실행한다');

    day.removeListener(second);
    final afterLastListener = clockReads;
    now = DateTime(2026, 10, 25);
    await tester.pump(const Duration(days: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(clockReads, afterLastListener, reason: '타이머와 복귀 관찰자를 모두 해제한다');

    // 구독 없는 동안 지난 날짜를 다음 화면의 첫 build에 남기지 않는다.
    expect(day.value, DateTime(2026, 10, 25));
    day.addListener(second);
    expect(day.value, DateTime(2026, 10, 25));
    day.removeListener(second);
  });

  testWidgets('백그라운드에서는 타이머를 멈추고 복귀 시 빠진 날짜를 한 번 갱신한다', (tester) async {
    var now = DateTime(2026, 12, 31, 23, 59, 58);
    final day = CurrentDay(now: () => now);
    addTearDown(day.dispose);
    var calls = 0;
    void listener() => calls++;
    day.addListener(listener);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = DateTime(2027, 1, 3, 12);
    await tester.pump(const Duration(days: 3));
    expect(calls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(day.value, DateTime(2027, 1, 3));
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(calls, 1, reason: '같은 날짜의 복귀로는 다시 알리지 않는다');
    now = DateTime(2027, 1, 4);
    await tester.pump(const Duration(hours: 12));
    expect(day.value, DateTime(2027, 1, 4));
    expect(calls, 2);
    day.removeListener(listener);
  });

  testWidgets('알림 콜백 안에서 마지막 구독을 해제해도 관찰자를 정리한다', (tester) async {
    var now = DateTime(2026, 10, 23, 23, 59, 59);
    var reads = 0;
    final day = CurrentDay(
      now: () {
        reads++;
        return now;
      },
    );
    addTearDown(day.dispose);
    late VoidCallback listener;
    listener = () => day.removeListener(listener);
    day.addListener(listener);
    now = DateTime(2026, 10, 24);
    await tester.pump(const Duration(seconds: 1));
    final afterRemoval = reads;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(days: 1));
    expect(reads, afterRemoval);
  });
}
