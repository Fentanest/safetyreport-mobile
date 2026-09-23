@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/widgets/report_list_card.dart';
import 'package:safetyreport/widgets/stats_overview_section.dart';

import '../support/ui_harness.dart';
import '../widgets/stats_overview_section_test.dart' show fixtureSummary;

/// 리뉴얼 시범 컴포넌트 골든. 기준 갱신(--update-goldens)은 사용자가 렌더를 승인한 커밋에서만 한다.
void main() {
  String? skipReason;

  setUpAll(() async {
    skipReason = await loadGoldenFonts();
  });

  for (final brightness in Brightness.values) {
    testWidgets('신고 카드 골든 (${brightness.name})', (tester) async {
      if (skipReason != null) {
        markTestSkipped(skipReason!);
        return;
      }
      final errors = await pumpThemed(
        tester,
        _GoldenFrame(
          child: Column(
            children: [
              ReportListCard(
                report: longFieldReport(),
                selectionMode: false,
                isSelected: false,
                onTap: () {},
                onLongPress: () {},
                metaItems: [
                  ReportCardMetaItem(
                    icon: Icons.calendar_today,
                    text: '신고 2026-09-22',
                  ),
                  ReportCardMetaItem(
                    icon: Icons.place,
                    text: longFieldReport().location,
                  ),
                  ReportCardMetaItem(
                    icon: Icons.business,
                    text: longFieldReport().agency,
                  ),
                ],
              ),
              ReportListCard(
                report: longFieldReport(status: '수용'),
                selectionMode: true,
                isSelected: true,
                onTap: () {},
                onLongPress: () {},
                metaItems: const [],
              ),
            ],
          ),
        ),
        brightness: brightness,
      );
      expect(errors, isEmpty, reason: describeErrors(errors));
      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/report_list_card_${brightness.name}.png'),
      );
    });

    testWidgets('통계 요약 골든 (${brightness.name})', (tester) async {
      if (skipReason != null) {
        markTestSkipped(skipReason!);
        return;
      }
      final errors = await pumpThemed(
        tester,
        _GoldenFrame(
          child: StatsOverviewSection(
            summary: fixtureSummary(months: 8),
            categoryLabel: '교통위반',
            yearBasis: '신고일',
          ),
        ),
        brightness: brightness,
        height: 900,
      );
      expect(errors, isEmpty, reason: describeErrors(errors));
      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/stats_overview_${brightness.name}.png'),
      );
    });
  }
}

/// 골든 캡처 영역에 실제 화면 배경을 깐다(투명 배경이면 다크 글자 대비를 판단할 수 없다).
class _GoldenFrame extends StatelessWidget {
  final Widget child;

  const _GoldenFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: const ValueKey('golden'),
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Padding(padding: const EdgeInsets.all(8), child: child),
      ),
    );
  }
}
