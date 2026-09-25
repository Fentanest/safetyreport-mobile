import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/attachment_policy.dart';

void main() {
  final now = DateTime(2026, 9, 24);
  test('cutoff is six months back as YYYY-MM-DD (same as server)', () {
    expect(attachmentCutoff(now), '2026-03-24');
    expect(attachmentCutoff(DateTime(2026, 3, 10)), '2025-09-10');
  });
  test('month-end days clamp like the server relativedelta', () {
    // 서버: date(2026,8,31) - relativedelta(months=6) == 2026-02-28 (넘쳐서 3월로 가지 않음)
    expect(attachmentCutoff(DateTime(2026, 8, 31)), '2026-02-28');
    expect(attachmentCutoff(DateTime(2026, 3, 31)), '2025-09-30');
    expect(attachmentCutoff(DateTime(2028, 8, 30)), '2028-02-29');
    expect(attachmentCutoff(DateTime(2026, 12, 31)), '2026-06-30');
  });
  test('reports older than the cutoff have expired attachments', () {
    expect(attachmentsExpired('2026-03-23 10:00:00', now: now), isTrue);
    expect(attachmentsExpired('2026-03-24', now: now), isFalse);
    expect(attachmentsExpired('2026-09-01', now: now), isFalse);
    expect(attachmentsExpired('', now: now), isFalse);
  });
}
