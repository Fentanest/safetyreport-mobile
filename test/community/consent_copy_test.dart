// 공유 동의문은 앱에 넣어 두지 않는다(2026-09-27) — 중앙 `policy` 로 받는다(계약 account-api.md).
// 동의문 원본은 지도 저장소 contracts/consent/ 에만 있고 이 저장소로 복사하지 않는다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the app bundles no consent text or policy constant', () {
    expect(Directory('assets/community').existsSync() && Directory('assets/community').listSync().isNotEmpty, isFalse);
    expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('assets/community/')));
    expect(Directory('contracts/community-ingest/consent').existsSync(), isFalse,
        reason: '계약 사본에도 동의문을 두지 않는다 — 원본은 지도 저장소 contracts/consent/(복사하지 않음)');
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final src = f.readAsStringSync();
      expect(src, isNot(contains('share-consent-')), reason: f.path);
      expect(src, isNot(contains('communityRequiredPolicyVersion')), reason: f.path);
    }
  });
}
