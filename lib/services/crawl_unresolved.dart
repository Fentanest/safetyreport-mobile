/// 서버 대기 큐에서 처리하지 못하고 뺀 신고번호(`GET /api/v1/crawl/status` 의 추가 필드 `unresolved`, 서버 감사 R7-03·R8-02).
/// 필드가 없는 구서버면 빈 목록.
class CrawlUnresolved {
  const CrawlUnresolved({
    required this.number,
    required this.reason,
    this.at = '',
  });

  final String number;

  /// 서버가 기록한 시각(ISO). 같은 번호가 다시 기록되면 바뀐다.
  final String at;

  /// 'not_found'(목록 전체에 없음) 또는 'ambiguous'(여러 신고에 걸림).
  final String reason;

  String get message => reason == 'ambiguous'
      ? '여러 신고에 걸려 처리하지 못했습니다 — 정확한 신고번호로 다시 요청하세요'
      : '신고 목록 전체에서 찾지 못했습니다';

  static List<CrawlUnresolved> fromStatus(Map<String, dynamic> status) {
    final raw = status['unresolved'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map && e['number'] is String)
          CrawlUnresolved(
            number: e['number'] as String,
            reason: (e['reason'] ?? '').toString(),
            at: (e['at'] ?? '').toString(),
          ),
    ];
  }

  /// 화면 갱신 판단: 길이가 같아도 번호·사유·시각이 하나라도 다르면 다른 목록(서버는 최근 50개를 유지 — 서버 감사 R9-03).
  static bool sameList(List<CrawlUnresolved> a, List<CrawlUnresolved> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].number != b[i].number ||
          a[i].reason != b[i].reason ||
          a[i].at != b[i].at) {
        return false;
      }
    }
    return true;
  }
}
