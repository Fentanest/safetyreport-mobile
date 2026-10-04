import 'package:flutter/material.dart';

/// 모서리 반경 단계(`docs/design/ui-renewal-spec.md` §4: sm 4 / md 8 / lg 12 / xl 16 / 2xl 24 + 알약).
/// 화면 코드는 리터럴 대신 이 상수를 쓴다(SQ-U23). 규격 밖 값은 `test/theme/design_token_scan_test.dart` 가 막는다.
abstract final class SrRadius {
  /// 작은 꼬리표·진행 막대.
  static const double sm = 4;

  /// 작은 칩·지도 라벨·코드 블록.
  static const double md = 8;

  /// 카드·입력칸·버튼·아이콘 타일(`CardTheme`·`FilledButton` 과 같은 값).
  static const double lg = 12;

  /// 대화상자·큰 패널.
  static const double xl = 16;

  /// 바텀시트 위 모서리.
  static const double xxl = 24;

  /// 알약(높이의 절반 이상이면 모두 같은 모양).
  static const double pill = 999;
}

/// 글자 크기 단계(spec §3: Display 32 · H1 24 · H2 20 · H3 18 · Body1 16 · Body2 14 · Caption 12).
/// 12 미만은 쓰지 않는다 — 예외는 차트 축 눈금 [chartAxis](11) 하나(SQ-U19).
abstract final class SrFontSize {
  /// Caption 12/16 — 앱의 최소 글자(배지·칩·메타 정보·하단 내비 라벨).
  static const double caption = 12;

  /// 차트 축 눈금 전용. 다른 곳에 쓰지 않는다.
  static const double chartAxis = 11;
}

/// 자주 쓰는 작은 글자 스타일. 색은 호출부에서 `copyWith(color: …)` 로 준다.
/// `ThemeData.textTheme` 의 `bodySmall`/`labelSmall` 도 같은 크기로 맞췄다(`AppTheme`).
abstract final class SrTextStyles {
  /// 보조 설명·메타 정보(12).
  static const caption = TextStyle(fontSize: SrFontSize.caption);

  /// 배지·칩 라벨(12, 굵게).
  static const badge = TextStyle(
    fontSize: SrFontSize.caption,
    fontWeight: FontWeight.w700,
  );

  /// 차트 축 눈금(11).
  static const chartAxis = TextStyle(fontSize: SrFontSize.chartAxis);
}
