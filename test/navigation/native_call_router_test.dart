// SQ-B05: Kotlin → Dart 호출 처리기는 앱 루트에서 한 번 걸고, 메인 화면 수명과 무관하게 동작한다.
// - 메인 화면이 붙기 전 navigateToTab 은 보관했다가 붙은 뒤 전달한다(콜드 스타트·초기화 화면 중 유실 방지).
// - syncFgsStopped 는 메인 화면이 없어도 SyncEngine 에 닿는다.
// - 화면이 사라진 뒤의 요청은 옛 화면의 context 를 쓰지 않고 다시 보관한다.
// - start() 는 Kotlin 에 dartReady 를 보낸다(보류한 알림 탭 요청을 보내라는 신호).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/navigation/native_call_router.dart';
import 'package:safetyreport/services/sync_engine.dart';

class _Target implements NativeNavTarget {
  final requests = <NativeNavRequest>[];

  @override
  Future<void> handleNativeNavigation(NativeNavRequest request) async {
    requests.add(request);
  }
}

const _channelName = 'com.fentanest.mysafetyreport/permissions';

Future<void> _fromNative(String method, [Object? args]) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channelName,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
}

void main() {
  late List<MethodCall> toNative;
  final router = NativeCallRouter.instance;

  setUp(() {
    toNative = [];
    router.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCallRouter.channel, (call) async {
          toNative.add(call);
          if (call.method == 'startSyncFgs') return true;
          return null;
        });
  });

  tearDown(() {
    router.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeCallRouter.channel, null);
  });

  testWidgets('start() installs the handler and sends dartReady', (
    tester,
  ) async {
    await router.start();
    expect(toNative.map((c) => c.method), contains('dartReady'));
  });

  testWidgets(
    'navigateToTab before the main screen is delivered once after attach',
    (tester) async {
      await router.start();
      await _fromNative('navigateToTab', {
        'tab': 4,
        'sub_tab': 1,
        'event_type': '',
        'payload_json': '{"신고번호":"SPP-1"}',
      });
      expect(router.pendingRequest, isNotNull, reason: '화면이 없으면 보관한다');

      final target = _Target();
      await tester.pumpWidget(const SizedBox());
      router.attach(target);
      expect(
        target.requests,
        isEmpty,
        reason: 'attach(initState) 안에서 바로 처리하지 않는다',
      );
      await tester.pump();
      expect(target.requests, hasLength(1));
      final r = target.requests.single;
      expect(r.tab, 4);
      expect(r.subTab, 1);
      expect(r.payloadJson, '{"신고번호":"SPP-1"}');
      expect(router.pendingRequest, isNull);

      await tester.pump();
      expect(target.requests, hasLength(1), reason: '한 번만 전달');
    },
  );

  testWidgets(
    'only the latest pending request is kept; attached target gets live requests',
    (tester) async {
      router.install();
      await _fromNative('navigateToTab', {'tab': 1});
      await _fromNative('navigateToTab', {
        'tab': 6,
        'event_type': 'quick_sync',
      });
      final target = _Target();
      router.attach(target);
      await tester.pump();
      expect(target.requests.map((r) => r.tab), [6]);
      expect(target.requests.single.eventType, 'quick_sync');

      await _fromNative('navigateToTab', {'tab': 3, 'sub_tab': -1});
      expect(target.requests.map((r) => r.tab), [6, 3]);
      expect(target.requests.last.subTab, isNull);
    },
  );

  testWidgets(
    'after detach, requests are buffered instead of hitting the old screen',
    (tester) async {
      router.install();
      final old = _Target();
      router.attach(old);
      router.detach(old);
      await _fromNative('navigateToTab', {'tab': 2});
      expect(old.requests, isEmpty);
      expect(router.pendingRequest?.tab, 2);

      final next = _Target();
      router.attach(next);
      // 다른 화면의 detach 는 지금 붙은 화면을 떼지 않는다.
      router.detach(old);
      await tester.pump();
      expect(next.requests.map((r) => r.tab), [2]);
      expect(router.hasTarget, isTrue);
    },
  );

  testWidgets('syncFgsStopped reaches SyncEngine without any main screen', (
    tester,
  ) async {
    router.install();
    expect(router.hasTarget, isFalse);
    await SyncEngine.acquireFgs('테스트 동기화');
    addTearDown(SyncEngine.releaseFgs);
    final start = toNative.lastWhere((c) => c.method == 'startSyncFgs');
    final owner = (start.arguments as Map)['owner'] as String;
    expect(SyncEngine.fgsActive.value, isTrue);

    await _fromNative('syncFgsStopped', {'owner': owner, 'reason': 'timeout'});
    expect(SyncEngine.fgsActive.value, isFalse);
    expect(SyncEngine.stopRequested, isTrue);
  });
}
