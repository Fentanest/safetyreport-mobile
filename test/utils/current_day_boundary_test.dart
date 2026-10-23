import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/utils/current_day.dart';

void main() {
  testWidgets('첫 날짜 읽기와 구독 사이에 자정이 지나도 새 날짜를 표시한다', (tester) async {
    var reads = 0;
    final day = CurrentDay(
      now: () => reads++ == 0
          ? DateTime(2026, 10, 23, 23, 59, 59, 999)
          : DateTime(2026, 10, 24),
    );
    addTearDown(day.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<DateTime>(
          valueListenable: day,
          builder: (context, value, _) => Text('오늘 ${value.day}일'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('오늘 24일'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
