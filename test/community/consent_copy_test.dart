// 공유 동의문은 앱에 넣어 두지 않는다(2026-09-27) — 중앙 `policy` 로 받는다(계약 account-api.md).
// 계약 사본(contracts/community-ingest/consent)은 중앙 migration 의 원본을 그대로 옮긴 것일 뿐 앱이 읽지 않는다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the app bundles no consent text or policy constant', () {
    expect(Directory('assets/community').existsSync() && Directory('assets/community').listSync().isNotEmpty, isFalse);
    expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('assets/community/')));
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final src = f.readAsStringSync();
      expect(src, isNot(contains('share-consent-')), reason: f.path);
      expect(src, isNot(contains('communityRequiredPolicyVersion')), reason: f.path);
    }
  });
}
