import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 설정의 기기 이름을 공유 연결의 표시 이름으로 쓴다.
/// 중앙 계정 API의 device_label 규칙(최대 40자, 제어·마크업 문자 금지)에 맞춘다.
class CommunityDeviceLabel {
  static const _channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  static Future<String> read() async {
    final fallback = defaultTargetPlatform == TargetPlatform.iOS
        ? 'iPhone'
        : 'Android 기기';
    try {
      final name = await _channel
          .invokeMethod<String>('getDeviceName')
          .timeout(const Duration(seconds: 3));
      return normalize(name, fallback: fallback);
    } catch (_) {
      return fallback;
    }
  }

  static String normalize(String? raw, {String fallback = 'Android 기기'}) {
    final cleaned = (raw ?? '')
        .replaceAll(
          RegExp(
            r'''[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069<>"'`\\]''',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty ||
        RegExp(
          r'^[a-z][a-z0-9+.-]*:',
          caseSensitive: false,
        ).hasMatch(cleaned)) {
      return fallback;
    }
    return String.fromCharCodes(cleaned.runes.take(40));
  }

  static String connectionDisplayName(
    Map<String, Object?> connection,
    String? localName,
  ) {
    final source = connection['source_app'];
    final name = source == 'safetyreport-mobile'
        ? (localName ?? '이 기기')
        : source == 'safetyreport'
        ? 'PC 서버'
        : '연결 기기';
    final status = switch (connection['status']) {
      'active' => '연결됨',
      'superseded' => '다른 기기로 전환됨',
      'revoked' => '연결 해제됨',
      'suspended' => '일시 중지됨',
      _ => '상태 확인 필요',
    };
    return '$name · $status';
  }
}
