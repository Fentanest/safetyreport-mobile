// SQ-B13: Standalone 초기화 게이트는 "건너뛰기(onDone)"를 build 마다 예약하지 않고 한 번만, 살아 있을 때만 부른다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/main.dart';

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

  testWidgets('store error: onDone fires exactly once', (tester) async {
    final calls = await pumpGate(
      tester,
      () async => throw StateError('store unavailable'),
    );
    expect(calls(), 1);
  });
}
