// SQ-B07 / SQ-B09 / SQ-U18 — 크롤링(Client) 화면의 상태 폴링·로그 WebSocket 생명주기와 로그 패널.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/crawl_screen.dart';
import 'package:safetyreport/services/api_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/theme/sr_colors.dart';

class _ClientProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.server;
  @override
  String get baseUrl => 'http://fixture.invalid';
  @override
  String get apiKey => 'fixture-key';
}

class _FakeApi extends ApiService {
  _FakeApi() : super(baseUrl: 'http://fixture.invalid', apiKey: 'fixture-key');

  Completer<Map<String, dynamic>>? configGate;
  bool running = false;
  int statusCalls = 0;

  @override
  Future<Map<String, dynamic>> getCrawlConfig() async {
    final gate = configGate;
    if (gate != null) return gate.future;
    return {'crawl_mode': 'full'};
  }

  @override
  Future<Map<String, dynamic>> getCrawlStatus() async {
    statusCalls++;
    return {'running': running};
  }
}

class _FakeWs extends Fake implements WebSocket {
  final controller = StreamController<dynamic>();
  bool closed = false;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future close([int? code, String? reason]) async {
    closed = true;
    await controller.close();
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => controller.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

const _panelColor = Color(0xFF1E1E1E);

/// 실제 Android 순서대로 생명주기를 옮긴다(AppLifecycleListener 가 건너뛰기를 거부한다).
void _toBackground(WidgetTester tester) {
  for (final s in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void _toForeground(WidgetTester tester) {
  for (final s in const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void main() {
  late _ClientProvider provider;
  late _FakeApi api;

  setUp(() {
    provider = _ClientProvider();
    api = _FakeApi();
  });

  tearDown(() => provider.dispose());

  Widget host({
    Future<WebSocket> Function(ApiService api)? connect,
    Brightness brightness = Brightness.light,
  }) => ChangeNotifierProvider<ReportProvider>.value(
    value: provider,
    child: MaterialApp(
      theme: AppTheme.build(brightness),
      home: CrawlScreen(
        apiFactory: (_) => api,
        connectLogSocket:
            connect ?? (_) async => throw const SocketException('no ws'),
      ),
    ),
  );

  testWidgets('SQ-B07: status polling restarts after paused -> resumed', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(api.statusCalls, 1, reason: 'initial status check');

    await tester.pump(const Duration(seconds: 5));
    expect(api.statusCalls, 2, reason: '5s polling while visible');

    _toBackground(tester);
    await tester.pump(const Duration(seconds: 20));
    expect(api.statusCalls, 2, reason: 'no polling in background');

    _toForeground(tester);
    await tester.pump();
    expect(api.statusCalls, 3, reason: 'immediate check on resume');

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(api.statusCalls, 5, reason: 'polling resumed after resume');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    expect(api.statusCalls, 5, reason: 'no polling after dispose');
  });

  testWidgets('SQ-B07/B09: closing during slow init leaves no timer/setState', (
    tester,
  ) async {
    api.configGate = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(host());
    await tester.pump();
    expect(api.statusCalls, 0);

    // 설정 응답 전에 화면을 닫는다.
    await tester.pumpWidget(const SizedBox());
    api.configGate!.complete({'crawl_mode': 'reset'});
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));

    expect(tester.takeException(), isNull);
    expect(api.statusCalls, 0, reason: 'no status check/poll after dispose');
  });

  testWidgets('SQ-B07: a log WebSocket that connects after dispose is closed', (
    tester,
  ) async {
    api.running = true;
    final gate = Completer<WebSocket>();
    await tester.pumpWidget(host(connect: (_) => gate.future));
    await tester.pump();
    expect(api.statusCalls, 1);

    await tester.pumpWidget(const SizedBox());
    final ws = _FakeWs();
    gate.complete(ws);
    await tester.pump();

    expect(ws.closed, isTrue, reason: 'late socket must not stay open');
    expect(tester.takeException(), isNull);
  });

  testWidgets('SQ-B07: dispose closes an open log WebSocket', (tester) async {
    api.running = true;
    final ws = _FakeWs();
    await tester.pumpWidget(host(connect: (_) async => ws));
    await tester.pump();
    expect(ws.closed, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(ws.closed, isTrue);
  });

  group('SQ-U18 log panel', () {
    Iterable<Text> panelTexts(WidgetTester tester) => tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const Key('crawl-log-panel')),
        matching: find.byType(Text),
      ),
    );

    testWidgets('empty log panel is compact and readable in light theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host());
      await tester.pump();

      expect(find.text('로그 없음'), findsOneWidget);
      final panel = tester.getSize(find.byKey(const Key('crawl-log-panel')));
      expect(panel.height, lessThan(80), reason: 'empty panel must not fill');

      for (final t in panelTexts(tester)) {
        final style = t.style!;
        expect(
          contrastRatio(style.color!, _panelColor),
          greaterThanOrEqualTo(4.5),
          reason: '"${t.data}" on the dark panel',
        );
        expect(style.fontSize, greaterThanOrEqualTo(12));
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('log lines expand the panel with >=4.5:1 text in light theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      api.running = true;
      final ws = _FakeWs();
      await tester.pumpWidget(host(connect: (_) async => ws));
      await tester.pump();
      final controlsBefore = tester.state(find.byType(RefreshIndicator));
      ws.controller.add('[1/3] SPP-1 조회\n[2/3] SPP-2 조회');
      await tester.pump();
      await tester.pump();

      expect(find.text('[1/3] SPP-1 조회'), findsOneWidget);
      expect(
        identical(tester.state(find.byType(RefreshIndicator)), controlsBefore),
        isTrue,
        reason: 'control area keeps its state when the panel expands',
      );
      final panel = tester.getSize(find.byKey(const Key('crawl-log-panel')));
      expect(panel.height, greaterThan(200), reason: 'logs get the room');

      for (final t in panelTexts(tester)) {
        final style = t.style!;
        expect(
          contrastRatio(style.color!, _panelColor),
          greaterThanOrEqualTo(4.5),
          reason: '"${t.data}" on the dark panel',
        );
        expect(style.fontSize, greaterThanOrEqualTo(12));
      }
      await tester.pumpWidget(const SizedBox());
    });
  });
}
