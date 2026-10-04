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

  // L-7: 세로 화면 + 키보드 + 큰 글자에서 사유 입력칸이 한 줄만 보이고 도움말·글자 수가 가려지던 문제.
  Future<void> openDialog(WidgetTester tester, double scale) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<({int score, String cause})>(
                context: context,
                builder: (_) => const RatingDialog(
                  count: 20,
                  eligibleCount: 17,
                  causeSupported: true,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets(
      'portrait 360x740 + IME 300 scale=$scale: reason shows 3+ lines and counter',
      (tester) async {
        await openDialog(tester, scale);
        await tester.showKeyboard(find.byType(TextField));
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final viewport = tester.getRect(
          find
              .ancestor(
                of: find.byType(TextField),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final visible = viewport.intersect(
          const Rect.fromLTWH(0, 0, 360, 740 - 300),
        );
        bool inside(Rect r) =>
            r.top >= visible.top - 0.5 && r.bottom <= visible.bottom + 0.5;

        final editable = tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable;
        final editableRect = tester.getRect(find.byType(EditableText));
        expect(
          inside(editableRect),
          isTrue,
          reason: '$editableRect / $visible',
        );
        expect(
          editableRect.height,
          greaterThanOrEqualTo(editable.preferredLineHeight * 3 - 0.5),
        );
        final counter = find.text('0 / ${RatingService.ratingCauseMax}자');
        expect(counter, findsOneWidget);
        expect(inside(tester.getRect(counter)), isTrue);
        expect(
          find.widgetWithText(FilledButton, '확인').hitTestable(),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextButton, '취소').hitTestable(),
          findsOneWidget,
        );

        // 키보드를 닫으면 설명 문구가 돌아온다.
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('진행 가능 17건'), findsOneWidget);
      },
    );
  }

  testWidgets('selected score chip shows fill only, no checkmark', (
    tester,
  ) async {
    await openDialog(tester, 1.0);
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
    expect(chips, hasLength(5));
    for (final chip in chips) {
      expect(chip.showCheckmark, isFalse);
    }
    expect(chips.where((c) => c.selected), hasLength(1));
  });
}
