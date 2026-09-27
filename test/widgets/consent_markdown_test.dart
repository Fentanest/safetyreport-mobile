import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/widgets/consent_markdown.dart';

Iterable<TextSpan> _allSpans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? <InlineSpan>[]) {
      yield* _allSpans(child);
    }
  }
}

String _renderedText(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .map((widget) => widget.textSpan?.toPlainText() ?? widget.data ?? '')
    .join('\n');

void main() {
  testWidgets('real consent document renders Markdown without raw markers', (
    tester,
  ) async {
    final source = File(
      'test/fixtures/share-consent-2026-09-28.1.md', // copy of the map repository's contracts/consent (the app gets the text from the center)
    ).readAsStringSync();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ConsentMarkdown(text: source)),
        ),
      ),
    );

    final rendered = _renderedText(tester);
    expect(rendered, isNot(contains('**')));
    expect(rendered, isNot(contains('|')));
    expect(rendered, isNot(contains('](')));
    expect(rendered.split('\n').where((line) => line.startsWith('#')), isEmpty);
    // two-column table on a phone: first cell as the card title, no repeated column labels
    expect(rendered, contains('신고와 처리 결과\n신고일, 답변 완료일'));
    expect(rendered, isNot(contains('구분:')));
    expect(rendered, contains('답변 완료일'));
    expect(rendered, contains('문의 게시판'));
    expect(rendered, contains('커뮤니티 신고 지도'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('only allowlisted HTTPS links get tap recognizers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConsentMarkdown(
            text:
                '[안전한 링크](https://github.com/Fentanest) '
                '[외부 링크](https://example.com/path) '
                '[닮은 도메인](https://github.com.evil.example/path) '
                '[스크립트](javascript:alert) '
                '[데이터](data:text/plain,hi)',
          ),
        ),
      ),
    );

    final widgets = tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    );
    final spans = widgets
        .where((widget) => widget.textSpan != null)
        .expand((widget) => _allSpans(widget.textSpan!))
        .toList();
    expect(
      spans
          .where((span) => span.recognizer is TapGestureRecognizer)
          .map((span) => span.text),
      ['안전한 링크'],
    );
    final rendered = _renderedText(tester);
    expect(rendered, contains('외부 링크 (https://example.com/path)'));
    expect(rendered, contains('닮은 도메인 (https://github.com.evil.example/path)'));
    expect(rendered, contains('스크립트 (javascript:alert)'));
    expect(rendered, contains('데이터 (data:text/plain,hi)'));
  });

  testWidgets('headings, lists, and inline formatting keep unknown syntax', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConsentMarkdown(
            text:
                '### 작은 제목\n\n- **첫 항목**\n- `둘째 항목`\n\n'
                '알 수 없는 ~~표시~~',
          ),
        ),
      ),
    );

    final rendered = _renderedText(tester);
    expect(rendered, contains('작은 제목'));
    expect(rendered, contains('첫 항목'));
    expect(rendered, contains('둘째 항목'));
    expect(rendered, contains('알 수 없는 ~~표시~~'));
    expect(rendered, isNot(contains('**')));
    expect(rendered, isNot(contains('`')));
    expect(tester.takeException(), isNull);
  });
}
