import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/utils/report_display_text.dart';
import 'package:safetyreport/widgets/report_list_card.dart';

/// 원문·식별자를 fixture/로그/이미지로 복사하지 않고 외부 예시 DB를 읽기만 한다.
/// 실행: SR_TEXT_MOBILE_DB=... SR_TEXT_SERVER_DB=... flutter test <이 파일>
void main() {
  final mobilePath = Platform.environment['SR_TEXT_MOBILE_DB'];
  final serverPath = Platform.environment['SR_TEXT_SERVER_DB'];
  final enabled = mobilePath != null && serverPath != null;
  final skipReason = enabled
      ? false
      : '실DB 전용: SR_TEXT_MOBILE_DB와 SR_TEXT_SERVER_DB 지정 필요';
  final sources = <String, List<Map<String, Object?>>>{};
  final lineEnd = RegExp(r'\r\n|\r|\n');
  final br = RegExp(r'<br\s*/?>', caseSensitive: false);
  const fields = ['신고명', '신고내용', '처리내용', '보완_요청_내용', '보완_신고자_의견', '별점사유'];

  setUpAll(() async {
    if (!enabled) return;
    sqfliteFfiInit();
    for (final source in [
      ('mobile', mobilePath, 'reports'),
      ('server', serverPath, 'mysafety_report'),
    ]) {
      final db = await databaseFactoryFfi.openDatabase(
        source.$2,
        options: OpenDatabaseOptions(readOnly: true),
      );
      try {
        sources[source.$1] = await db.query(source.$3);
      } finally {
        await db.close();
      }
    }
  });

  test('실제 저장 문구의 엔터티·br만 복원하고 본문 개행과 꺾쇠 문구를 보존한다', () {
    const entities = {
      '&quot;': '"',
      '&apos;': "'",
      '&#39;': "'",
      '&lt;': '<',
      '&gt;': '>',
      '&amp;': '&',
    };
    var checked = 0, entityValues = 0, brValues = 0, angleValues = 0;
    for (final rows in sources.values) {
      for (final row in rows) {
        for (final field in fields) {
          final raw = row[field]?.toString() ?? '';
          final shown = reportDisplayText(raw);
          final entityMatches = RegExp(
            r'&(?:quot|apos|lt|gt|amp|#39);',
          ).allMatches(raw);
          final breaks = br.allMatches(raw).length;
          // 실제 예시에 등장하는 엔터티를 한 번씩만 치환하는 독립 기대값.
          final expected = raw
              .replaceAll(br, '\n')
              .replaceAllMapped(
                RegExp(r'&(?:quot|apos|lt|gt|amp|#39);'),
                (m) => entities[m[0]]!,
              );
          expect(shown == expected, isTrue, reason: '실제 문구의 표시 변환 불일치');
          expect(row[field]?.toString() == raw || row[field] == null, isTrue);
          if (entityMatches.isNotEmpty) entityValues++;
          if (breaks > 0) brValues++;
          final literalAngles = RegExp(
            r'<[^>]+>',
          ).allMatches(raw).where((m) => !br.hasMatch(m[0]!));
          for (final span in literalAngles) {
            expect(shown.contains(span[0]!), isTrue, reason: '꺾쇠 문구가 사라짐');
            angleValues++;
          }
          expect(
            '\n'.allMatches(shown).length ==
                '\n'.allMatches(raw).length + breaks,
            isTrue,
            reason: '기존 본문 개행을 늘리거나 줄이면 안 됨',
          );
          checked++;
        }
      }
    }
    expect(entityValues > 0 && brValues > 0 && angleValues > 0, isTrue);
    // 집계만 출력한다. 원문·신고번호·계정·주소는 출력하지 않는다.
    // ignore: avoid_print
    print(
      '실DB 표시 검증: 필드 $checked개, 엔터티 $entityValues개, br $brValues개, 꺾쇠 $angleValues개',
    );
  }, skip: skipReason);

  test('실제 제목의 빈 줄만 미리보기에서 제거하고 상세용 제목은 유지한다', () {
    var blankTitles = 0;
    for (final rows in sources.values) {
      for (final row in rows) {
        final raw = row['신고명']?.toString() ?? '';
        final shown = reportDisplayText(raw);
        final lines = shown.split(lineEnd);
        final preview = reportTitlePreview(raw);
        if (lines.any((line) => line.trim().isEmpty) &&
            shown.trim().isNotEmpty) {
          blankTitles++;
        }
        expect(
          preview == lines.where((line) => line.trim().isNotEmpty).join('\n'),
          isTrue,
          reason: '제목의 비어있지 않은 줄을 변경하면 안 됨',
        );
        expect(row['신고명']?.toString() == raw || row['신고명'] == null, isTrue);
      }
    }
    expect(blankTitles > 0, isTrue);
  }, skip: skipReason);

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('실제 빈 줄 제목 카드 렌더 ${brightness.name}/$scale', (tester) async {
        final row = sources['mobile']!.firstWhere((row) {
          final raw = row['신고명']?.toString() ?? '';
          final lines = raw.split(lineEnd);
          return lines.take(2).any((line) => line.trim().isEmpty) &&
              lines.where((line) => line.trim().isNotEmpty).length >= 2;
        });
        final report = Report.fromJson(Map<String, dynamic>.from(row));
        final original = report.name;
        final expected = reportTitlePreview(original);
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final errors = <FlutterErrorDetails>[];
        final oldHandler = FlutterError.onError;
        FlutterError.onError = errors.add;
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.build(brightness),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: ListView(
                    children: [
                      ReportListCard(
                        report: report,
                        selectionMode: false,
                        isSelected: false,
                        onTap: () {},
                        onLongPress: () {},
                        metaItems: const [],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final titles = tester
              .widgetList<Text>(find.byType(Text))
              .where((text) => text.data == expected && text.maxLines == 2);
          expect(titles.length == 1, isTrue, reason: '카드에 표시용 제목이 없음');
          expect(report.name == original, isTrue, reason: '모델 원문 변경 금지');
          expect(errors.isEmpty, isTrue, reason: '실제 제목 카드 렌더 오류');
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          FlutterError.onError = oldHandler;
        }
      }, skip: !enabled);
    }
  }
}
