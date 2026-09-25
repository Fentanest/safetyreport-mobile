// 동의문 번들 사본이 계약과 바이트 동일 + sha256 일치.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled consent equals contract copy with matching sha256', () {
    final bundled =
        File('assets/community/share-consent-2026-09-26.1.md').readAsBytesSync();
    final contract = File(
      'contracts/community-ingest/consent/share-consent-2026-09-26.1.md',
    ).readAsBytesSync();
    expect(bundled, contract);
    final recorded = File(
      'contracts/community-ingest/consent/share-consent-2026-09-26.1.sha256',
    ).readAsStringSync().split(' ').first.trim();
    expect(sha256.convert(bundled).toString(), recorded);
  });
}
