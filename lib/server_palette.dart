import 'package:flutter/material.dart';

const serverSupplementColor = Color(0xFFFD7E14);
const serverProcessingColor = Color(0xFF6C757D);
const serverCompletedColor = Color(0xFF0DCAF0);
const serverRejectColor = Color(0xFFDC3545);
const serverAcceptColor = Color(0xFF198754);
const serverPartialAcceptColor = Color(0xFFFFC107);
const serverWithdrawColor = Color(0xFF6C757D);

const serverTrafficFineColor = Color(0xFFE83E8C);
const serverTrafficPenaltyColor = Color(0xFF6C757D);

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
  return Colors.grey;
}

Color serverFineColor(String fine) {
  final value = fine.trim();
  if (value.contains('과태료')) return serverTrafficFineColor;
  if (value.contains('경고') || value.contains('범칙금')) {
    return serverTrafficPenaltyColor;
  }
  return Colors.grey;
}
