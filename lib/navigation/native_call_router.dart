import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../services/sync_engine.dart' show SyncEngine;

/// MainActivity 가 보내는 `navigateToTab` 요청(알림 탭·런처 바로가기·감지 알림).
@immutable
class NativeNavRequest {
  const NativeNavRequest({
    required this.tab,
    this.subTab,
    this.eventType = '',
    this.payloadJson = '',
  });

  factory NativeNavRequest.fromArguments(Object? arguments) {
    final args = arguments is Map ? arguments : const {};
    final subTab = (args['sub_tab'] as num?)?.toInt();
    return NativeNavRequest(
      tab: (args['tab'] as num?)?.toInt() ?? 4,
      subTab: subTab != null && subTab >= 0 ? subTab : null,
      eventType: args['event_type']?.toString() ?? '',
      payloadJson: args['payload_json']?.toString() ?? '',
    );
  }

  /// 하단 탭 0~4, 또는 옛 인덱스 5(파일)·6(동기화/크롤링).
  final int tab;
  final int? subTab;
  final String eventType;
  final String payloadJson;
}

/// 내비게이션 요청을 받아 처리하는 화면(메인 하단 탭 화면).
abstract interface class NativeNavTarget {
  Future<void> handleNativeNavigation(NativeNavRequest request);
}

/// `com.fentanest.mysafetyreport/permissions` 채널의 Kotlin → Dart 호출 처리기(SQ-B05).
///
/// - 앱 루트에서 한 번 건다([start]). 화면 수명과 무관해서 사라진 화면의 context 를 쓰지 않는다.
/// - `navigateToTab` 은 메인 화면이 붙을 때([attach])까지 마지막 요청 하나를 보관했다가 전달한다
///   (콜드 스타트의 보안 저장소 이관·게이트·서버 확인, Standalone 초기화 화면 동안 유실되던 요청).
/// - `syncFgsStopped` 는 화면이 없어도 [SyncEngine] 으로 보낸다.
/// - [start] 는 Kotlin 에 `dartReady` 를 보낸다. Kotlin 은 그때까지 보류한 알림 탭 요청을 보낸다.
class NativeCallRouter {
  NativeCallRouter._();

  static final NativeCallRouter instance = NativeCallRouter._();

  static const MethodChannel channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  NativeNavTarget? _target;
  NativeNavRequest? _pending;
  bool _flushScheduled = false;

  /// 앱 시작 때 부른다: 처리기를 걸고 Kotlin 에 준비됨을 알린다.
  Future<void> start() async {
    install();
    try {
      await channel.invokeMethod<void>('dartReady');
    } catch (_) {
      // 예전 네이티브(또는 시험 환경)는 dartReady 를 모른다 — 기존 지연 전송 경로가 남아 있다.
    }
  }

  /// 처리기만 건다(같은 처리기라 여러 번 불러도 같다).
  void install() => channel.setMethodCallHandler(_handle);

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'syncFgsStopped':
        final args = call.arguments;
        SyncEngine.onNativeFgsStopped(
          args is Map ? args['owner'] as String? : null,
        );
        return null;
      case 'navigateToTab':
        final request = NativeNavRequest.fromArguments(call.arguments);
        final target = _target;
        if (target == null) {
          _pending = request;
          return null;
        }
        await target.handleNativeNavigation(request);
        return null;
    }
    throw MissingPluginException('${call.method} is not handled by Dart');
  }

  /// 메인 화면이 준비됐다. 보관한 요청은 다음 프레임에 전달한다(initState 안에서 setState 하지 않게).
  void attach(NativeNavTarget target) {
    install();
    _target = target;
    if (_pending == null || _flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      final current = _target;
      final pending = _pending;
      if (current == null || pending == null) return;
      _pending = null;
      unawaited(current.handleNativeNavigation(pending));
    });
    // 프레임 밖에서 붙어도(시험·재연결) 다음 프레임이 돌아 보관한 요청이 전달되게 한다.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 메인 화면이 사라진다. 이후 요청은 다시 보관한다.
  void detach(NativeNavTarget target) {
    if (identical(_target, target)) _target = null;
  }

  @visibleForTesting
  NativeNavRequest? get pendingRequest => _pending;

  @visibleForTesting
  bool get hasTarget => _target != null;

  @visibleForTesting
  void resetForTest() {
    _target = null;
    _pending = null;
    _flushScheduled = false;
  }
}
