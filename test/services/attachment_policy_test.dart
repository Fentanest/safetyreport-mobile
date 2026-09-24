import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/attachment_policy.dart';

void main() {
  final now = DateTime(2026, 9, 24);
  test('cutoff is six months back as YYYY-MM-DD (same as server)', () {
    expect(attachmentCutoff(now), '2026-03-24');
    expect(attachmentCutoff(DateTime(2026, 3, 10)), '2025-09-10');
  });
  test('reports older than the cutoff have expired attachments', () {
    expect(attachmentsExpired('2026-03-23 10:00:00', now: now), isTrue);
    expect(attachmentsExpired('2026-03-24', now: now), isFalse);
    expect(attachmentsExpired('2026-09-01', now: now), isFalse);
    expect(attachmentsExpired('', now: now), isFalse);
  });
}
