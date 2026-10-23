import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/data_editor_screen.dart';
import 'package:safetyreport/services/report_filter_spec.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/search_filter_sheet.dart';
import 'package:sqlite3/sqlite3.dart';

// 원본은 readOnly로만 연다. 내용·ID를 fixture/로그/이미지/파일에 복제하지 않는다.
final _sources = [
  (Platform.environment['SR_TEXT_MOBILE_DB'] ?? '', 'reports'),
  (Platform.environment['SR_TEXT_SERVER_DB'] ?? '', 'mysafety_report'),
];

String? _readText(
  (String, String) source,
  String field, {
  bool multiline = true,
}) {
  if (source.$1.isEmpty || !File(source.$1).existsSync()) return null;
  final db = sqlite3.open(source.$1, mode: OpenMode.readOnly);
  try {
    final rows = db.select(
      'SELECT "$field" FROM "${source.$2}" WHERE length("$field")>0 '
      '${multiline ? 'AND instr("$field",char(10))>0 ' : ''}'
      'ORDER BY length("$field") LIMIT 1',
    );
    return rows.isEmpty ? null : rows.first[field] as String;
  } finally {
    db.close();
  }
}

Future<void> _openSearch(
  WidgetTester tester,
  ReportProvider provider,
  ValueChanged<ReportFilter> onApply,
) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: Builder(
        builder: (c) {
          context = c;
          return const Scaffold();
        },
      ),
    ),
  );
  // 설정하지 않은 실제 Provider라 metadata 네트워크 조회는 시작하지 않는다.
  expect(provider.isConfigured, isFalse);
  showSearchFilterSheet(context, provider: provider, onApply: onApply);
  await tester.pumpAndSettle();
}

String _queryValue(ReportFilter filter, String field) => switch (field) {
  '신고명' => filter.name,
  '신고내용' => filter.reportContent,
  '처리내용' => filter.processContent,
  '별점사유' => filter.ratingCause,
  _ => filter.reportNumber,
};

void main() {
  for (final source in _sources) {
    for (final field in ['신고명', '신고내용', '처리내용', '별점사유']) {
      testWidgets('실제 ${source.$2} $field 개행을 검색 제출까지 보존한다', (tester) async {
        final text = _readText(source, field);
        if (text == null) {
          markTestSkipped('읽기 전용 실제 DB의 해당 개행 값이 필요합니다.');
          return;
        }
        final provider = ReportProvider();
        addTearDown(provider.dispose);
        ReportFilter? applied;
        await _openSearch(tester, provider, (value) => applied = value);
        final more = find.byKey(const ValueKey('search-filter-more'));
        await tester.ensureVisible(more);
        await tester.tap(more);
        await tester.pumpAndSettle();
        final input = find.byKey(ValueKey('search-input-$field'));
        await tester.ensureVisible(input);
        await tester.enterText(input, text);
        await tester.pump();
        final widget = tester.widget<TextField>(input);
        // 비교 실패 시 실제 텍스트를 출력하지 않는다.
        expect(widget.controller!.text == text, isTrue);
        expect(widget.minLines, 1);
        expect(widget.maxLines, 3);
        expect(widget.keyboardType, TextInputType.multiline);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(applied != null, isTrue);
        final query = _queryValue(applied!, field);
        expect(query == text.trim(), isTrue);
        expect(ReportFilterSpec.matchesText(text, query), isTrue);
        expect(find.byType(SearchFilterSheet), findsNothing);
      });
    }

    testWidgets('실제 ${source.$2} 신고번호의 단일행 검색 동선을 유지한다', (tester) async {
      final text = _readText(source, '신고번호', multiline: false);
      if (text == null) {
        markTestSkipped('읽기 전용 실제 DB가 필요합니다.');
        return;
      }
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      ReportFilter? applied;
      await _openSearch(tester, provider, (value) => applied = value);
      final input = find.byKey(const ValueKey('search-input-신고번호'));
      await tester.enterText(input, text);
      expect(tester.widget<TextField>(input).maxLines, 1);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(applied?.reportNumber == text.trim(), isTrue);
    });

    for (final field in ['신고내용', '처리내용', '첨부사진', '첨부파일', '위반법규']) {
      testWidgets('실제 ${source.$2} $field 수정 입력은 줄바꿈 키와 원문을 유지한다', (
        tester,
      ) async {
        final text =
            _readText(source, field) ??
            _readText(source, field, multiline: false);
        if (text == null) {
          markTestSkipped('읽기 전용 실제 DB의 해당 값이 필요합니다.');
          return;
        }
        final controller = TextEditingController(text: text);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(Brightness.dark),
            home: Scaffold(
              body: ReportEditorTextField(
                field: field,
                controller: controller,
                decoration: InputDecoration(labelText: field),
              ),
            ),
          ),
        );
        final input = find.byKey(ValueKey('editor-input-$field'));
        await tester.enterText(input, text);
        await tester.pump();
        expect(
          tester.testTextInput.setClientArgs?['inputAction'],
          'TextInputAction.newline',
        );
        expect(controller.text == text, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
