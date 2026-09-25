/// 6개월 지난 신고의 첨부(지도·사진·파일)는 원본 링크가 만료돼 보여 주지 않는다.
/// 서버 core/storage/reports_repo.py `_apply_attachment_expiry` 와 같은 규칙:
/// 신고일 문자열 < (오늘 - 6개월)의 'YYYY-MM-DD' 이면 만료. 서버는 화면용 표에만 "6개월 초과"를 쓰고
/// 원본은 보존하므로, 앱도 원본을 두고 화면에서만 가린다(저장 계층 재설계 R2).
library;

/// 오늘 - 6개월. 서버 `relativedelta(months=6)` 와 같게, 그 달에 없는 날이면 말일로(8/31 → 2/28).
String attachmentCutoff(DateTime now) {
  var year = now.year;
  var month = now.month - 6;
  if (month < 1) {
    month += 12;
    year -= 1;
  }
  final lastDay = DateTime(year, month + 1, 0).day;
  final day = now.day > lastDay ? lastDay : now.day;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${year.toString().padLeft(4, '0')}-${two(month)}-${two(day)}';
}

bool attachmentsExpired(String reportDate, {DateTime? now}) {
  if (reportDate.isEmpty) return false;
  return reportDate.compareTo(attachmentCutoff(now ?? DateTime.now())) < 0;
}
