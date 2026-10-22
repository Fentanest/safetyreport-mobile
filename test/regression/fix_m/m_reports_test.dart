// FIX-M 회귀 시험: 진행 보고 60초 억제(R1-7, D5), 설정 단계 보고 옛 서버(R1-9, D6), 진행 보고 503 문구(R1-10),
// 백그라운드 사용자 조치 알림(R1-6), 알림 엔진의 바인딩 순서(R1-8).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/community/backfill_progress.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/notify/user_action_notifier.dart';
import 'package:safetyreport/community/report/report_env.dart';
import 'package:safetyreport/community/report/setup_progress_reporter.dart';
import 'package:safetyreport/community/upload_pause.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../community/report/report_test_support.dart';

Future<void> _marker(CommunityStore store, String state) => store.setMeta(
  'raw_backfill',
  jsonEncode({
    'run_id': '1761094800000000-1',
    'state': state,
    'phase': 'uploading',
    'run_started_at': 1761094800,
    'updated_at': 1761094800,
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(ReportEnv.reset);

  group('R1-7 / D5 진행 보고', () {
    late FakeNet net;
    late CommunityStore store;
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: 'standalone',
      });
      UserActionNotifier.permissionGranted = () async => false;
      net = FakeNet((_) => http.Response('{"protocol":1,"stored":true}', 200))
        ..install();
      BackfillProgress.clock = () => net.clock;
      BackfillProgress.resetForTest();
      UploadPause.scheduleForTest = (d) async {};
      store = await openReportStore();
    });
    tearDown(() => UploadPause.scheduleForTest = null);

    List<Object?> sentStates() => [
      for (final r in net.requests)
        (jsonDecode(r.body) as Map)['backfill']['state'],
    ];

    test('start 뒤 60초 안에 done 이 되어도 done 은 다음 tick 에 나간다', () async {
      await _marker(store, 'uploading');
      await BackfillProgress.report(store, start: true);
      expect(net.requests.length, 1);
      net.advance(const Duration(seconds: 30));
      await _marker(store, 'done');
      await BackfillProgress.report(store); // 60초 억제로 건너뜀 — 키는 그대로
      expect(net.requests.length, 1);
      net.advance(const Duration(seconds: 40));
      await BackfillProgress.report(store);
      expect(sentStates(), ['uploading', 'done']);
      // 그 뒤 같은 날에는 done 을 다시 보내지 않는다(하루 1번).
      for (var i = 0; i < 5; i++) {
        net.advance(const Duration(minutes: 30));
        await BackfillProgress.report(store);
      }
      expect(sentStates(), ['uploading', 'done']);
    });

    test('R1-10: 진행 보고가 받은 503 maintenance 의 운영자 문구를 버리지 않고 저장한다', () async {
      await _marker(store, 'uploading');
      net.handler = (_) => http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'error': {
              'code': 'maintenance',
              'retryable': true,
              'resume_at': '2026-10-22T06:30:00.000Z',
              'pause_message': '서버 저장 공간을 늘리는 중입니다.',
            },
          }),
        ),
        503,
        headers: {'retry-after': '1800'},
      );
      await BackfillProgress.report(store, start: true);
      final pause = await UploadPause.read(store);
      expect(pause, isNotNull);
      expect(pause!.message, '서버 저장 공간을 늘리는 중입니다.');
    });
  });

  group('R1-9 / D6 설정 단계 보고', () {
    late FakeNet net;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      net = FakeNet((_) => http.Response('{"error":{"code":"not_found"}}', 404))
        ..install();
    });

    Future<void> report() => SetupProgressReporter.report(
      stage: 'consent_ok',
      mode: 'standalone',
    );

    test('404(옛 서버)는 보낸 것으로 치고 24시간 동안 같은 내용을 다시 보내지 않는다', () async {
      await report();
      for (var i = 0; i < 12; i++) {
        net.advance(const Duration(minutes: 5));
        await report();
      }
      expect(net.requests, hasLength(1));
      net.advance(const Duration(hours: 24));
      await report();
      expect(net.requests, hasLength(2));
    });

    test('400 도 같다. 내용이 바뀌면 바로 보낸다', () async {
      net.handler = (_) =>
          http.Response('{"error":{"code":"invalid_request"}}', 400);
      await report();
      net.advance(const Duration(minutes: 5));
      await report();
      expect(net.requests, hasLength(1));
      await SetupProgressReporter.report(
        stage: 'official_login_started',
        mode: 'standalone',
      );
      expect(net.requests, hasLength(2));
    });

    test('429·5xx·네트워크는 기록하지 않고 다음 호출에 다시 보낸다', () async {
      for (final h in <http.Response Function(http.Request)>[
        (_) => http.Response('{}', 429, headers: {'retry-after': '60'}),
        (_) => http.Response('{}', 503),
        (_) => throw http.ClientException('offline'),
      ]) {
        SharedPreferences.setMockInitialValues({});
        net.requests.clear();
        net.handler = h;
        await report();
        net.advance(const Duration(minutes: 2));
        await report();
        expect(net.requests, hasLength(2));
      }
    });
  });

  group('R1-6 백그라운드 엔진의 사용자 조치 알림', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      UserActionNotifier.permissionGranted = () async => true;
      ReportEnv.now = () => DateTime.utc(2026, 10, 22, 3);
    });

    test('알림 채널이 없으면(WorkManager 엔진) 공용 저장소 키로 Kotlin 에 넘기고 오늘 알린 것으로 친다', () async {
      // 시험 환경에는 MethodChannel 처리기가 없다 = WorkManager 엔진과 같다(MissingPluginException).
      await UserActionNotifier.evaluate(
        backfillReason: null,
        officialLoginManual: false,
        optimizeBlockedInBackground: true,
        staleHolds: 0,
        updateRequired: false,
      );
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(UserActionNotifier.prefsAlert);
      expect(raw, isNotNull);
      final alert = jsonDecode(raw!) as Map;
      expect(alert['event_type'], 'user_action_optimize_blocked_background');
      expect(alert['body'], '신고 공유를 이어 가려면 앱을 한 번 열어 주세요.');
      expect(alert['at'], isA<int>());
      expect(
        prefs.getString(
          UserActionNotifier.prefsLastDay(
            UserActionNotifier.reasonOptimizeBlocked,
          ),
        ),
        '2026-10-22',
      );
    });

    test('Kotlin 리스너가 같은 키 이름을 듣는다', () {
      final kt = File(
        'android/app/src/main/kotlin/com/fentanest/mysafetyreport/SafetyReportApplication.kt',
      ).readAsStringSync();
      expect(kt, contains('"flutter.${UserActionNotifier.prefsAlert}"'));
      expect(kt, contains('registerOnSharedPreferenceChangeListener(userActionListener)'));
    });
  });

  test('R1-8: 알림 엔진은 바인딩을 먼저 만들고 앱 버전을 읽는다', () {
    final src = File(
      'lib/services/notification_background.dart',
    ).readAsStringSync();
    final body = src.substring(src.indexOf('Future<void> runNotificationBackground()'));
    final binding = body.indexOf('WidgetsFlutterBinding.ensureInitialized()');
    final version = body.indexOf('AppVersion.load()');
    expect(binding, greaterThanOrEqualTo(0));
    expect(version, greaterThan(binding));
  });
}
