import '../models/report.dart';
import '../services/report_policy.dart';

final _calendarDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:$|[ T])');

/// 저장된 신고일·답변일의 달력 날짜만 사용한다. UTC 자정끼리 빼서
/// 시각·일광절약시간 때문에 하루가 줄어들지 않게 한다.
DateTime? _parseCalendarDate(String value) {
  final text = value.trim();
  final match = _calendarDate.firstMatch(text);
  if (match == null || DateTime.tryParse(text) == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime.utc(year, month, day);
  // DateTime은 2월 30일 등을 다음 달로 넘기므로 원래 값과 대조한다.
  if (date.year != year || date.month != month || date.day != day) return null;
  return date;
}

/// 완료 건은 답변까지의 소요일, 처리중 건은 오늘까지의 경과일을 표시한다.
/// 취하·이송·보완요청·미상 상태는 진행 여부를 추측하지 않는다.
String? reportDurationLabel(Report report, {DateTime? today}) {
  final completed = ReportPolicy.isCompleted(report.status);
  if (!completed && !ReportPolicy.isProcessing(report.status)) return null;
  final reported = _parseCalendarDate(report.date);
  if (reported == null) return null;
  final now = today ?? DateTime.now();
  final end = completed
      ? _parseCalendarDate(report.responseDate)
      : DateTime.utc(now.year, now.month, now.day);
  if (end == null) return null;
  final days = end.difference(reported).inDays;
  if (days < 0) return null;
  return '${completed ? '소요' : '경과'} $days일';
}
