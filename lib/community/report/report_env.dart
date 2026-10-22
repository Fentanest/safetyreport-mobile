// 진행 보고·설정 단계 보고가 함께 쓰는 환경 읽기(설정·토큰·버전·플랫폼·시계).
// 시험은 아래 hook 을 바꿔 끼운다. 비밀값(토큰·키)은 로그·결과 기록에 남기지 않는다.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../services/community_auth_config.dart';
import '../../services/community_auth_service.dart';

class ReportEnv {
  ReportEnv._();

  @visibleForTesting
  static CommunityAuthConfig? configOverride;
  @visibleForTesting
  static Future<String?> Function()? tokenOverride;
  @visibleForTesting
  static Future<String?> Function()? versionOverride;
  @visibleForTesting
  static String? platformOverride;

  /// 시계(시험이 바꿔 끼운다).
  static DateTime Function() now = DateTime.now;
  @visibleForTesting
  static http.Client Function()? clientFactory;

  @visibleForTesting
  static void reset() {
    configOverride = null;
    tokenOverride = null;
    versionOverride = null;
    platformOverride = null;
    now = DateTime.now;
    clientFactory = null;
  }

  static CommunityAuthConfig get config =>
      configOverride ?? CommunityAuthConfig.fromEnvironment;

  static Future<String?> accessToken() async {
    final o = tokenOverride;
    if (o != null) return o();
    final r = await CommunityAuthService.instance.getAccessTokenResult();
    return r.status == CommunityTokenStatus.ok ? r.accessToken : null;
  }

  /// 빌드 번호를 뗀 앱 버전. 못 읽으면 null.
  static Future<String?> appVersion() async {
    try {
      final o = versionOverride;
      final raw = o != null
          ? await o()
          : (await PackageInfo.fromPlatform()).version;
      if (raw == null) return null;
      final v = raw.split('+').first.trim();
      return RegExp(r'^[0-9][0-9A-Za-z.+_-]{0,39}$').hasMatch(v) ? v : null;
    } catch (_) {
      return null;
    }
  }

  static String platform() =>
      platformOverride ??
      (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');

  /// 헤더 `X-Client-App` 값(6-3).
  static String clientApp() => 'mobile/${platform()}';

  static http.Client newClient() => (clientFactory ?? http.Client.new)();

  /// 기기 KST(UTC+9) 날짜 `YYYY-MM-DD`. 기기 시간대와 상관없이 KST 로 고정한다.
  static String kstDate(DateTime t) {
    final k = t.toUtc().add(const Duration(hours: 9));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${k.year.toString().padLeft(4, '0')}-${two(k.month)}-${two(k.day)}';
  }
}
