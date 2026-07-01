import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static const _channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  // ── 알림 리스너 권한 ──────────────────────────────────────────────────────
  static Future<bool> isNotificationListenerEnabled() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isNotificationListenerEnabled',
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> openNotificationListenerSettings() async {
    await _channel.invokeMethod('openNotificationListenerSettings');
  }

  // ── 배터리 최적화 제외 ─────────────────────────────────────────────────────
  static Future<bool> isBatteryOptimizationIgnored() async {
    return await Permission.ignoreBatteryOptimizations.isGranted;
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    await Permission.ignoreBatteryOptimizations.request();
  }

  // ── 알림 표시 권한 (Android 13+) ─────────────────────────────────────────
  static Future<bool> isNotificationPermissionGranted() async {
    return await Permission.notification.isGranted;
  }

  static Future<void> requestNotificationPermission() async {
    await Permission.notification.request();
  }

  // ── 위치 권한 (신고 지도 현재 위치 표시) ─────────────────────────────────────
  // 위치는 geolocator 스택 하나로 통일한다. permission_handler 와 이중으로
  // 권한을 물어보지 않도록 확인/요청/설정 이동 모두 geolocator 경유로 처리한다.
  static Future<bool> isLocationPermissionGranted() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  static Future<LocationPermission> requestLocationPermission() async {
    return Geolocator.requestPermission();
  }

  static Future<bool> openAppPermissionSettings() {
    return Geolocator.openAppSettings();
  }

  // ── WsService 제어 ────────────────────────────────────────────────────────
  /// 백그라운드 WebSocket 서비스를 시작합니다.
  static Future<bool> startWsService() async {
    try {
      return await _channel.invokeMethod<bool>('startWsService') ?? false;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('WsService 시작 오류: ${e.message}');
      return false;
    }
  }

  /// 백그라운드 WebSocket 서비스를 중지합니다.
  static Future<bool> stopWsService() async {
    try {
      return await _channel.invokeMethod<bool>('stopWsService') ?? false;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('WsService 중지 오류: ${e.message}');
      return false;
    }
  }

  /// 백그라운드 WebSocket 서비스 실행 여부를 반환합니다.
  static Future<bool> isWsServiceRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isWsServiceRunning') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
