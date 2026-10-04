import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/notification_item.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/notifications_screen.dart';
import 'package:safetyreport/server_palette.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/theme/sr_colors.dart';
import 'package:safetyreport/widgets/sr_snack_bar.dart';
import 'package:safetyreport/widgets/status_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 상태색이 시안(D-02)으로 바뀌면서 흰 글자 채움 배지는 대부분 AA 미달이 된다.
/// 배지·카드 글자는 StatusTone 으로 보정하고, 이 테스트가 두 테마 모두 4.5:1 이상을 보장한다.
const _statusColors = {
  '보완요청': serverSupplementColor,
  '처리중': serverProcessingColor,
  '답변완료': serverCompletedColor,
  '불수용/기타': serverRejectColor,
  '수용': serverAcceptColor,
  '일부수용': serverPartialAcceptColor,
  '취하': serverWithdrawColor,
  '과태료': serverTrafficFineColor,
  '경고/범칙금': serverTrafficPenaltyColor,
  '미확인': serverUnconfirmedColor,
};

/// 실제로 그려진 글자 색과, 글자를 감싼 가장 가까운 칠한 상자(배지 배경)의 대비.
double _renderedChipContrast(WidgetTester tester, Finder text) {
  final fg = tester.renderObject<RenderParagraph>(text).text.style!.color!;
  final box = tester
      .widgetList<DecoratedBox>(
        find.ancestor(of: text, matching: find.byType(DecoratedBox)),
      )
      .map((d) => d.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.color != null);
  final surface = Theme.of(tester.element(text)).colorScheme.surface;
  return contrastRatio(fg, Color.alphaBlend(box.color!, surface));
}

void main() {
  test('contrastRatio 는 반투명 전경을 배경에 합성해 계산한다', () {
    // white70 on #1A73E8 : 합성 전 luminance 로 계산하면 4.5 로 거짓 통과한다(C2 검수).
    expect(
      contrastRatio(Colors.white70, const Color(0xFF1A73E8)),
      lessThan(3.1),
    );
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
  });

  for (final brightness in Brightness.values) {
    group('${brightness.name} 테마', () {
      final theme = AppTheme.build(brightness);
      final scheme = theme.colorScheme;
      final sr = theme.extension<SrColors>()!;

      test('본문/보조 글자는 배경과 카드 위에서 AA', () {
        for (final bg in [sr.background, sr.surface]) {
          expect(contrastRatio(sr.textPrimary, bg), greaterThanOrEqualTo(4.5));
          expect(
            contrastRatio(sr.textSecondary, bg),
            greaterThanOrEqualTo(4.5),
          );
        }
      });

      test('컨테이너 색(토널 버튼·오류 박스) 글자 AA', () {
        for (final pair in [
          (scheme.onPrimaryContainer, scheme.primaryContainer),
          (scheme.onSecondaryContainer, scheme.secondaryContainer),
          (scheme.onErrorContainer, scheme.errorContainer),
          (scheme.onError, scheme.error),
          (scheme.onInverseSurface, scheme.inverseSurface),
        ]) {
          expect(contrastRatio(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
        }
      });

      test('SnackBar 성공/실패 배경 위 흰 글자 AA', () {
        expect(
          contrastRatio(Colors.white, srSnackSuccess),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(Colors.white, srSnackError),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('primary 글자·채움 버튼 대비', () {
        expect(
          contrastRatio(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
        );
        // 채움 버튼·선택 탭(웹과 같은 진한 파랑 + 흰 글자)
        final fill = theme.filledButtonTheme.style!.backgroundColor!.resolve(
          {},
        )!;
        expect(contrastRatio(Colors.white, fill), greaterThanOrEqualTo(4.5));
        expect(
          contrastRatio(scheme.primary, sr.surface),
          greaterThanOrEqualTo(4.5),
        );
      });

      for (final entry in _statusColors.entries) {
        test('상태 배지 ${entry.key}: 틴트 배경 위 글자 AA', () {
          for (final surface in [sr.surface, sr.background]) {
            final tone = StatusTone.of(
              entry.value,
              brightness: brightness,
              surface: surface,
            );
            expect(
              contrastRatio(tone.foreground, tone.background),
              greaterThanOrEqualTo(StatusTone.minContrast),
            );
            // 배지 글자를 배지 밖(카드 표면)에 쓸 때도 AA.
            expect(
              contrastRatio(tone.foreground, surface),
              greaterThanOrEqualTo(StatusTone.minContrast),
            );
          }
        });
      }

      // SQ-U23: 의미색·분류색 토큰. 원색(Colors.green 등)을 두 번 StatusTone 에 넣던 코드를 대신한다.
      test('의미색(success/warning/info) 글자는 배경·카드 위 AA', () {
        for (final color in [sr.success, sr.warning, sr.info]) {
          for (final bg in [sr.surface, sr.background]) {
            expect(
              contrastRatio(color, bg),
              greaterThanOrEqualTo(4.5),
              reason: '$color on $bg',
            );
          }
        }
      });

      test('의미색 채움(SnackBar·채운 버튼) 위 흰 글자 AA', () {
        for (final fill in [
          sr.successFill,
          sr.warningFill,
          sr.dangerFill,
          srSnackWarning,
        ]) {
          expect(contrastRatio(Colors.white, fill), greaterThanOrEqualTo(4.5));
        }
      });

      test('의미 톤·분류 톤 틴트 위 글자 AA (context.tone 과 같은 계산)', () {
        for (final base in [
          scheme.primary,
          sr.success,
          sr.warning,
          sr.info,
          scheme.error,
          sr.textSecondary,
          sr.categoryTraffic,
          sr.categoryParking,
          sr.categoryOther,
        ]) {
          for (final surface in [sr.surface, sr.background]) {
            final tone = StatusTone.of(
              base,
              brightness: brightness,
              surface: surface,
            );
            expect(
              contrastRatio(tone.foreground, tone.background),
              greaterThanOrEqualTo(StatusTone.minContrast),
              reason: '$base',
            );
            expect(
              contrastRatio(tone.foreground, surface),
              greaterThanOrEqualTo(StatusTone.minContrast),
              reason: '$base',
            );
          }
        }
      });

      test('분류색 키 매핑: 교통/주정차/기타는 서로 다르고 모르는 키는 보조색', () {
        final colors = {
          sr.category('traffic'),
          sr.category('parking'),
          sr.category('other'),
        };
        expect(colors, hasLength(3));
        expect(sr.category('traffic'), sr.categoryTraffic);
        expect(sr.category('???'), sr.textSecondary);
      });

      test('모드 배지(Client/Standalone) 글자 AA', () {
        for (final base in [sr.modeClient, sr.modeStandalone]) {
          final tone = StatusTone.of(
            base,
            brightness: brightness,
            surface: sr.background,
          );
          expect(
            contrastRatio(tone.foreground, tone.background),
            greaterThanOrEqualTo(4.5),
          );
        }
      });
    });
  }

  // SQ-U23: context.tone 은 현재 테마 표면 위 StatusTone 과 같고, showSrSnack 은 채움 + 흰 글자를 그린다.
  for (final brightness in Brightness.values) {
    testWidgets('context.tone / showSrSnack (${brightness.name})', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(brightness),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      final sr = ctx.sr;
      final expected = StatusTone.of(
        sr.success,
        brightness: brightness,
        surface: sr.surface,
      );
      expect(ctx.tone(SrTone.success).foreground, expected.foreground);
      expect(ctx.tone(SrTone.success).background, expected.background);
      expect(
        ctx.semantic(SrTone.danger),
        Theme.of(ctx).colorScheme.error,
      );

      for (final (kind, fill) in [
        (SrSnackKind.success, srSnackSuccess),
        (SrSnackKind.warning, srSnackWarning),
        (SrSnackKind.error, srSnackError),
      ]) {
        showSrSnack(ctx, '알림 $kind', kind: kind, hideCurrent: true);
        await tester.pump();
        final bar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(bar.backgroundColor, fill);
        final fg = tester
            .renderObject<RenderParagraph>(find.text('알림 $kind'))
            .text
            .style!
            .color!;
        expect(contrastRatio(fg, fill), greaterThanOrEqualTo(4.5));
      }

      // 정보형은 테마 기본(inverseSurface) 배경 + onInverseSurface 글자.
      showSrSnack(ctx, '정보', hideCurrent: true);
      await tester.pump();
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).backgroundColor, isNull);
      final infoFg = tester
          .renderObject<RenderParagraph>(find.text('정보'))
          .text
          .style!
          .color!;
      final scheme = Theme.of(ctx).colorScheme;
      expect(
        contrastRatio(infoFg, scheme.inverseSurface),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  // SQ-U13: 상세 시트·알림·지도의 상태 칩이 StatusBadge 를 우회해 원색 글자 + 옅은 배경으로 그려
  // 일부수용 1.96:1 등 AA 미달이었다. 이제 모두 StatusBadge 를 쓰고, 실제 렌더 색으로 검사한다.
  // (상세 시트 칩은 test/widgets/report_detail_sheet_wp4_test.dart 에서 검사한다.)
  for (final brightness in Brightness.values) {
    testWidgets(
      'SQ-U13 StatusBadge 렌더 대비 (${brightness.name}, 지도 주소 없음 배지 포함)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(brightness),
            home: Scaffold(
              body: Wrap(
                children: [
                  for (final entry in _statusColors.entries)
                    StatusBadge(label: entry.key, color: entry.value),
                  const StatusBadge(
                    label: '3건',
                    color: serverSupplementColor,
                    fontSize: 12,
                  ),
                ],
              ),
            ),
          ),
        );
        for (final label in [..._statusColors.keys, '3건']) {
          expect(
            _renderedChipContrast(tester, find.text(label)),
            greaterThanOrEqualTo(4.5),
            reason: label,
          );
        }
      },
    );

    testWidgets('SQ-U13 알림 신고 결과 칩 대비 (${brightness.name})', (tester) async {
      Map<String, dynamic> item(
        String id,
        String kind,
        Map<String, dynamic> extra,
      ) => NotificationItem(
        id: id,
        kind: kind,
        title: '처리 결과 $id',
        body: '본문',
        reportNumber: 'SPP-2610-000000$id',
        timestamp: '2026-10-04 10:00',
        isRead: false,
        extraData: extra,
      ).toJson();
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.notificationsHistory: jsonEncode([
          item('1', NotificationItemKind.report, {
            '처리상태': '일부수용',
            '범칙금_과태료': '과태료: 40,000원',
          }),
          item('2', NotificationItemKind.report, {'처리상태': '수용'}),
          item('3', NotificationItemKind.duplicate, {'status_label': '확정 중복'}),
        ]),
      });
      final report = ReportProvider();
      final history = NotificationHistoryProvider();
      addTearDown(report.dispose);
      addTearDown(history.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ReportProvider>.value(value: report),
            ChangeNotifierProvider<NotificationHistoryProvider>.value(
              value: history,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.build(brightness),
            home: const NotificationsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('신고 결과'));
      await tester.pumpAndSettle();
      for (final label in ['일부수용', '과태료', '수용', '확정 중복']) {
        expect(
          _renderedChipContrast(tester, find.text(label)),
          greaterThanOrEqualTo(4.5),
          reason: label,
        );
      }
    });
  }
}
