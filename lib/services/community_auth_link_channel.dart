import 'dart:async';

import 'package:flutter/services.dart';

/// Android `MainActivity` 가 받은 커뮤니티 로그인 복귀 링크를 Dart 로 가져온다.
///
/// - 네이티브는 `com.fentanest.mysafetyreport://auth/callback` (scheme/host/path 정확히 일치)만 잡아
///   한 칸짜리 보관함에 넣고 intent 에서 지운다(액티비티 재생성 때 다시 오지 않게).
/// - Dart 는 앱 시작 때 [start] 로 핸들러를 등록하고 `takePendingLink`(꺼내면서 비움)를 한 번 부른다.
///   이후 새 링크가 오면 네이티브가 `onCommunityAuthLink` 신호만 보내고, Dart 가 다시 `takePendingLink` 한다.
///   링크 원문은 한 경로(`takePendingLink`)로만 전달된다.
/// - 기존 `com.fentanest.mysafetyreport/permissions` 채널(`navigateToTab`)과 별개다.
class CommunityAuthLinkChannel {
  CommunityAuthLinkChannel._();

  static const channel = MethodChannel(
    'com.fentanest.mysafetyreport/community_auth',
  );

  static Future<void> Function(String link)? _onLink;

  /// 앱 시작 때 한 번(`main()`). SetupScreen 이든 설정 화면이든 링크를 받는다.
  static void start(Future<void> Function(String link) onLink) {
    _onLink = onLink;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onCommunityAuthLink') {
        await drain();
      }
      return null;
    });
    unawaited(drain());
    // iOS 콜드 스타트: AppDelegate 가 launchOptions URL 을 보관한다.
    // Android 에는 이 메서드가 없어 PlatformException → 무시된다.
    unawaited(drainInitial());
  }

  /// iOS `getInitialLink` 보관함의 링크를 꺼내 처리한다.
  static Future<void> drainInitial() async {
    final handler = _onLink;
    if (handler == null) return;
    String? link;
    try {
      link = await channel.invokeMethod<String>('getInitialLink');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    if (link == null || link.isEmpty) return;
    await handler(link);
  }

  /// 네이티브 보관함의 링크를 꺼내 처리한다. 채널이 없는 플랫폼(테스트·데스크톱)에서는 아무것도 안 한다.
  static Future<void> drain() async {
    final handler = _onLink;
    if (handler == null) return;
    String? link;
    try {
      link = await channel.invokeMethod<String>('takePendingLink');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    if (link == null || link.isEmpty) return;
    await handler(link);
  }
}
