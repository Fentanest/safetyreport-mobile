import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static const _channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  /// 테스트 주입용 플랫폼 재정의. null 이면 실제 플랫폼.
  static TargetPlatform? platformOverrideForTest;

  static TargetPlatform get platform =>
      platformOverrideForTest ?? defaultTargetPlatform;

  static bool get isIOS => platform == TargetPlatform.iOS;

  /// Android 전용 기능(알림 리스너·배터리 최적화·백그라운드 위치·WsService)은
  /// iOS 에서 표시·요청하지 않는다.
  static bool get supportsNotificationListener => !isIOS;
  static bool get supportsBatteryOptimization => !isIOS;
  static bool get supportsWsService => !isIOS;

  // 플랫폼 플러그인 확인 호출은 5초 타임아웃으로 fail-closed 한다.
  // 응답 없는 채널(iOS 의 Android 전용 채널, mock 없는 테스트 채널)이
  // 권한 화면을 영원히 멈추지 않게 한다.
  static const _checkTimeout = Duration(seconds: 5);

  // ── 알림 리스너 권한 (Android 전용) ─────────────────────────────────────────
  static Future<bool> isNotificationListenerEnabled() async {
    if (isIOS) return false;
    try {
      return await _channel
              .invokeMethod<bool>('isNotificationListenerEnabled')
              .timeout(_checkTimeout) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openNotificationListenerSettings() async {
    if (isIOS) return;
    try {
      await _channel.invokeMethod('openNotificationListenerSettings');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  // ── 배터리 최적화 제외 (Android 전용) ────────────────────────────────────────
  static Future<bool> isBatteryOptimizationIgnored() async {
    // iOS 에는 해당 개념이 없어 "해당 없음"(요구하지 않음)으로 처리한다.
    if (isIOS) return true;
    try {
      return await Permission.ignoreBatteryOptimizations.isGranted
          .timeout(_checkTimeout);
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (isIOS) return;
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}
  }

  // ── 알림 표시 권한 (Android 13+·iOS 공통) ────────────────────────────────────
  static Future<bool> isNotificationPermissionGranted() async {
    try {
      return await Permission.notification.isGranted.timeout(_checkTimeout);
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestNotificationPermission() async {
    try {
      await Permission.notification.request();
    } catch (_) {}
  }

  // ── 위치 권한 (신고 지도 현재 위치 표시) ─────────────────────────────────────
  // 위치는 geolocator 스택 하나로 통일한다. permission_handler 와 이중으로
  // 권한을 물어보지 않도록 확인/요청/설정 이동 모두 geolocator 경유로 처리한다.
  static Future<bool> isLocationPermissionGranted() async {
    try {
      final permission = await Geolocator.checkPermission().timeout(
        _checkTimeout,
      );
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<LocationPermission> requestLocationPermission() async {
    try {
      return await Geolocator.requestPermission();
    } on MissingPluginException {
      return LocationPermission.denied;
    } on PlatformException {
      return LocationPermission.denied;
    } catch (_) {
      return LocationPermission.denied;
    }
  }

  static Future<bool> openAppPermissionSettings() {
    try {
      return Geolocator.openAppSettings();
    } catch (_) {
      return Future.value(false);
    }
  }

  // ── WsService 제어 (Android 전용) ───────────────────────────────────────────
  /// 백그라운드 WebSocket 서비스를 시작합니다.
  static Future<bool> startWsService() async {
    if (isIOS) return false;
    try {
      return await _channel
              .invokeMethod<bool>('startWsService')
              .timeout(_checkTimeout) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('WsService 시작 오류: ${e.message}');
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 백그라운드 WebSocket 서비스를 중지합니다.
  static Future<bool> stopWsService() async {
    if (isIOS) return false;
    try {
      return await _channel
              .invokeMethod<bool>('stopWsService')
              .timeout(_checkTimeout) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('WsService 중지 오류: ${e.message}');
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 백그라운드 WebSocket 서비스 실행 여부를 반환합니다.
  static Future<bool> isWsServiceRunning() async {
    if (isIOS) return false;
    try {
      return await _channel
              .invokeMethod<bool>('isWsServiceRunning')
              .timeout(_checkTimeout) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
