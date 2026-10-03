import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/rating_dialog.dart';
import 'package:safetyreport/services/rating_service.dart';

void main() {
  for (final size in [const Size(360, 640), const Size(640, 360)]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'rating $size scale=$scale $brightness keyboard transitions keep actions reachable',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetViewInsets);
            ({int score, String cause})? result;
            await tester.pumpWidget(
              MaterialApp(
                theme: AppTheme.build(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () async {
                        result = await showDialog<({int score, String cause})>(
                          context: context,
                          builder: (_) => const RatingDialog(
                            count: 20,
                            eligibleCount: 17,
                            causeSupported: true,
                          ),
                        );
                      },
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('open'));
            await tester.pumpAndSettle();
            await tester.ensureVisible(
              find.byKey(const Key('rating-cause-field')),
            );
            await tester.enterText(
              find.byType(TextField),
              '첫 줄\r\n두 번째 줄\n세 번째 줄\n😀 마지막 줄',
            );
            for (final inset in [
              size.height * .42,
              0.0,
              size.height * .42,
              if (size.width > size.height) size.height * .70,
            ]) {
              tester.view.viewInsets = FakeViewPadding(bottom: inset);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              final confirm = find.widgetWithText(FilledButton, '확인');
              final cancel = find.widgetWithText(TextButton, '취소');
              expect(confirm.hitTestable(), findsOneWidget);
              expect(cancel.hitTestable(), findsOneWidget);
              final field = tester.widget<TextField>(find.byType(TextField));
              expect(field.controller!.text, contains('두 번째 줄'));
              expect(
                tester
                    .widget<EditableText>(find.byType(EditableText))
                    .focusNode
                    .hasFocus,
                isTrue,
              );
              if (size.width > size.height && inset > size.height * .6) {
                final visible = tester
                    .getRect(find.byType(TextField))
                    .intersect(
                      Rect.fromLTWH(0, 0, size.width, size.height - inset),
                    );
                expect(visible.height, greaterThan(24));
              }
            }
            await tester.tap(find.text('확인'));
            await tester.pumpAndSettle();
            expect(result, (score: 5, cause: '첫 줄\n두 번째 줄\n세 번째 줄\n😀 마지막 줄'));
          },
        );
      }
    }
  }
  testWidgets(
    'cancel never returns a submission and overlong input preserves its text',
    (tester) async {
      ({int score, String cause})? result;
      String draft = '';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                child: const Text('open'),
                onPressed: () async {
                  result = await showDialog<({int score, String cause})>(
                    context: ctx,
                    builder: (_) => RatingDialog(
                      count: 1,
                      eligibleCount: 1,
                      causeSupported: true,
                      onDraftChanged: (s) => draft = s,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final text = '😀' * (RatingService.ratingCauseMax + 1);
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '확인'))
            .onPressed,
        isNull,
      );
      expect(draft, text);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );
}
