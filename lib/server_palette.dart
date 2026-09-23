import 'package:flutter/material.dart';

// 상태·처분 기준색.
// 2026-09-24 UI 리뉴얼(D-02 선택지 c): 모바일이 디자인 토큰 상태색으로 먼저 바뀌었다.
// 서버 웹은 별도 작업으로 추종 예정이므로 그 전까지 웹과 모바일 배지 색이 다르다.
// 배지 글자/배경은 이 기준색을 `StatusTone`(lib/theme/sr_colors.dart)으로 변환해 AA 대비를 맞춘다.
const serverSupplementColor = Color(0xFFF97316);
const serverProcessingColor = Color(0xFF3B82F6);
const serverCompletedColor = Color(0xFF06B6D4);
const serverRejectColor = Color(0xFFEF4444);
const serverAcceptColor = Color(0xFF22C55E);
const serverPartialAcceptColor = Color(0xFFF59E0B);
const serverWithdrawColor = Color(0xFF94A3B8);

const serverTrafficFineColor = Color(0xFFEC4899);
const serverTrafficPenaltyColor = Color(0xFF8B5CF6);
const serverUnconfirmedColor = Color(0xFF6B7280);

// 변경 알림(카드 시트·알림 기록) 종류 색. 배지 글자는 StatusTone 으로 AA 보정해서 쓴다.
const changeNewColor = Color(0xFF14B8A6); // 신규
const changeStatusColor = Color(0xFFF59E0B); // 처리변경
const changeConfirmColor = Color(0xFF64748B); // 개별 확인
const changeDuplicateColor = Color(0xFF6366F1); // 중복 변경

Color serverStatusColor(String status) {
  final value = status.trim();
  if (value == '보완요청') return serverSupplementColor;
  if (value == '일부수용') return serverPartialAcceptColor;
  if (value.contains('수용') && !value.contains('불')) return serverAcceptColor;
  if (value.contains('불수용') || value == '기타') return serverRejectColor;
  if (value == '답변완료' || value.contains('완료')) return serverCompletedColor;
  if (value == '취하') return serverWithdrawColor;
  if (value.contains('처리') || value.contains('진행') || value.contains('검토')) {
    return serverProcessingColor;
  }
  return serverUnconfirmedColor;
}

Color serverFineColor(String fine) {
  final value = fine.trim();
  if (value.contains('과태료')) return serverTrafficFineColor;
  if (value.contains('경고') || value.contains('범칙금')) {
    return serverTrafficPenaltyColor;
  }
  return serverUnconfirmedColor;
}
