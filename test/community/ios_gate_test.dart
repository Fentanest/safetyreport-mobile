// iOS 복귀 경로 정적 검사 (Xcode 빌드는 NOT_RUN — 환경에 Xcode 없음).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Info.plist registers the community auth URL scheme', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('CFBundleURLTypes'));
    expect(plist, contains('com.fentanest.mysafetyreport'));
  });

  test('AppDelegate forwards callback links on the community_auth channel', () {
    final src = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(src, contains('com.fentanest.mysafetyreport/community_auth'));
    expect(src, contains('takePendingLink'));
    expect(src, contains('getInitialLink'));
    expect(src, contains('onCommunityAuthLink'));
    // Android 와 같은 판정: scheme/host/path 정확히 일치.
    expect(src, contains('/callback'));
    // 콜드 스타트 launchOptions URL 보관.
    expect(src, contains('launchOptions'));
  });
}
