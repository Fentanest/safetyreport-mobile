import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/server_palette.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/theme/sr_colors.dart';

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
}
