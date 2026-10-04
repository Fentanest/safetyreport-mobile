import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/consent_markdown.dart';

import '../support/ui_harness.dart';

/// Evidence only: CONSENT_SCREENSHOT=1 writes docs/reviews/screenshots/consent-markdown/mobile-390-*.png
/// (the whole consent document at phone width with the real Korean font, app light/dark theme). Skipped in normal runs.
void main() {
  final enabled = Platform.environment['CONSENT_SCREENSHOT'] == '1';
  testWidgets('consent document at 390 wide (screenshot)', (tester) async {
    final skip = await loadGoldenFonts();
    if (skip != null) {
      markTestSkipped(skip);
      return;
    }
    final source = File(
      'test/fixtures/share-consent-2026-09-28.1.md',
    ).readAsStringSync();
    for (final dark in [false, true]) {
      final key = GlobalKey();
      tester.view.physicalSize = const Size(390, 2600);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          // 앱 테마로 렌더한다(SQ-U28). 예전에는 기본 ThemeData(보라 #FEF7FF 바탕)라 실제 화면과 달랐다.
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: Builder(
                builder: (context) => ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ConsentMarkdown(text: source),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final out = File(
          'docs/reviews/screenshots/consent-markdown/mobile-390-${dark ? 'dark' : 'light'}.png',
        );
        out.parent.createSync(recursive: true);
        out.writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }, skip: !enabled);
}
