// 업로드 일시 중지(CLIENT-RULES 5절)·필수 버전 잠금(6절)·버전 헤더(6-3)·첫 실행 모드(7절) 시험. 네트워크 없음.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/capture/community_capture.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_account_client.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/gate/first_run_mode.dart';
import 'package:safetyreport/community/update_requirement.dart';
import 'package:safetyreport/community/upload_pause.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/screens/community_onboarding_screen.dart';
import 'package:safetyreport/screens/update_required_screen.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/widgets/upload_pause_banner.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/community/upload/community_uploader.dart' show UploadRunResult;
import 'package:safetyreport/community/upload/upload_background.dart' show HeadlessGate;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_account.dart';
import 'uploader_test.dart' as u;

Map<String, Object?> status({Object? requirement = const _Absent(), Object? ingest}) => {
  ...statusJson(),
  if (requirement is! _Absent) 'client_requirement': requirement,
  'ingest': ?ingest,
};

class _Absent {
  const _Absent();
}

Map<String, Object?> req(Object? mobile, {String? url, String? message}) => {
  'min_version': {'pc': '3.6.2', 'mobile': mobile},
  'url': {'pc': null, 'mobile': url},
  'message': message,
  'enforce_from': '2026-11-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('version compare (contracts/community-ingest-v2/version-vectors.json)', () {
    final vectors =
        jsonDecode(
              File(
                'contracts/community-ingest-v2/version-vectors.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final c in (vectors['cases'] as List).cast<Map>()) {
      test('${c['a']} vs ${c['b']} → ${c['cmp']}', () {
        expect(compareAppVersions(c['a'], c['b']), c['cmp']);
      });
    }
  });

  group('6-2 lock decision (no-hang first)', () {
    UpdateRequirement? decide(Map<String, Object?> s, [String mine = '2.5.0']) =>
        UpdateRequirement.decide(s, mine);
    test('explicit lower version locks', () {
      final r = decide(status(requirement: req('2.5.1', url: 'https://play.google.com/x', message: '안내')))!;
      expect(r.locked, isTrue);
      expect(r.minVersion, '2.5.1');
      expect(r.url, 'https://play.google.com/x');
      expect(r.message, '안내');
    });
    test('null requirement unlocks immediately', () {
      expect(decide(status(requirement: null))!.locked, isFalse);
    });
    test('my platform null → unlocked', () {
      expect(decide(status(requirement: req(null)))!.locked, isFalse);
    });
    test('same or newer → unlocked', () {
      expect(decide(status(requirement: req('2.5.0')))!.locked, isFalse);
      expect(decide(status(requirement: req('2.4.9')))!.locked, isFalse);
    });
    test('missing key keeps the last decision', () {
      expect(decide(status()), isNull);
    });
    test('unparseable versions keep the last decision', () {
      expect(decide(status(requirement: req('2.5.1-beta'))), isNull);
      expect(decide(status(requirement: req('2.5.1')), '2.5.0 dev'), isNull);
    });
    test('wrong shapes keep the last decision', () {
      expect(decide(status(requirement: 'x')), isNull);
      expect(decide(status(requirement: {'min_version': 'x'})), isNull);
      expect(decide(status(requirement: {'min_version': {'pc': '3.6.2'}})), isNull);
      expect(decide(status(requirement: req(7))), isNull);
    });
  });

  group('lock persistence and the gate', () {
    setUp(() {
      setUpSecureStorage();
      SharedPreferences.setMockInitialValues({});
      UpdateRequirement.versionForTest = '2.5.0';
      UpdateRequirement.current.value = UpdateRequirement.unlocked;
    });
    tearDown(() => UpdateRequirement.versionForTest = null);

    Future<(CommunityGate, FakeAccountServer)> gate(
      Map<String, Object?> Function() s,
    ) async {
      final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
      final server = FakeAccountServer(status: s);
      final g = CommunityGate(
        checkDataOwner: ownerOk,
        config: testAuthConfig(),
        auth: auth,
        accountClient: server.accountClient(),
        configStatus: () => 'ok',
        serverGate: pcGateOk,
        appMode: () => 'server',
      );
      addTearDown(g.dispose);
      return (g, server);
    }

    test('a normal status locks; timeout/5xx/malformed keep it; null unlocks', () async {
      Map<String, Object?> body = status(requirement: req('2.5.1'));
      final (g, server) = await gate(() => body);
      await g.refreshNow();
      expect(UpdateRequirement.isLocked, isTrue);
      // A restart reads the saved decision.
      UpdateRequirement.current.value = UpdateRequirement.unlocked;
      expect((await UpdateRequirement.load()).locked, isTrue);
      // 5xx: never decides.
      server.statusFailures = 1;
      await g.refreshNow();
      expect(UpdateRequirement.isLocked, isTrue);
      // Missing key: kept.
      body = status();
      await g.refreshNow();
      expect(UpdateRequirement.isLocked, isTrue);
      // Released requirement: unlocked at once.
      body = status(requirement: null);
      await g.refreshNow();
      expect(UpdateRequirement.isLocked, isFalse);
      expect((await UpdateRequirement.load()).locked, isFalse);
    });

    test('timeout / 5xx / malformed never lock (no-hang regression)', () async {
      for (final response in [
        http.Response('{"error":{"code":"busy"}}', 503),
        http.Response('<html>', 200),
        http.Response('[]', 200),
      ]) {
        final client = CommunityAccountClient(
          supabaseUrl: 'https://proj.supabase.test',
          publishableKey: 'sb_publishable_test',
          client: MockClient((_) async => response),
        );
        final g = CommunityGate(
          checkDataOwner: ownerOk,
          config: testAuthConfig(),
          auth: StubAuthService()..setPhase(CommunityAccountPhase.connected),
          accountClient: client,
          configStatus: () => 'ok',
          appMode: () => 'server',
        );
        addTearDown(g.dispose);
        await g.refreshNow();
        expect(UpdateRequirement.isLocked, isFalse);
      }
    });

    testWidgets('lock screen: title, body, version line, server message as plain text, update button', (tester) async {
      UpdateRequiredScreen.installerForTest = () async => 'com.android.vending';
      UpdateRequiredScreen.immediateUpdateForTest = () async => false;
      final opened = <Uri>[];
      UpdateRequiredScreen.launcherForTest = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() {
        UpdateRequiredScreen.installerForTest = null;
        UpdateRequiredScreen.immediateUpdateForTest = null;
        UpdateRequiredScreen.launcherForTest = null;
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: UpdateRequiredScreen(
            requirement: UpdateRequirement(
              locked: true,
              minVersion: '2.5.1',
              message: '<b>점검</b> 안내',
            ),
          ),
        ),
      );
      expect(find.text('앱을 업데이트해 주세요'), findsOneWidget);
      expect(find.textContaining('이 버전은 더 이상 신고를 공유할 수 없습니다.'), findsOneWidget);
      expect(find.text('필요한 버전: 2.5.1 이상'), findsOneWidget);
      expect(find.text('<b>점검</b> 안내'), findsOneWidget);
      await tester.tap(find.text('업데이트'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), playStoreUrl);
    });

    test('update target: Play first, GitHub APK goes to releases', () {
      const r = UpdateRequirement(locked: true, url: 'https://play.google.com/store/apps/details?id=com.fentanest.mysafetyreport');
      expect(updateTarget(r, 'com.android.vending').host, 'play.google.com');
      expect(updateTarget(r, 'com.google.android.packageinstaller').toString(), githubReleaseUrl);
      expect(updateTarget(const UpdateRequirement(locked: true), null).toString(), playStoreUrl);
      expect(updateTarget(const UpdateRequirement(locked: true, url: 'javascript:x'), null).toString(), playStoreUrl);
    });
  });

  group('6-3 version headers on every community-account request', () {
    tearDown(() => CommunityAccountClient.versionForTest = null);
    test('X-Client-Version and X-Client-App are sent', () async {
      CommunityAccountClient.versionForTest = '2.5.1';
      final headers = <Map<String, String>>[];
      final client = CommunityAccountClient(
        supabaseUrl: 'https://proj.supabase.test',
        publishableKey: 'k',
        client: MockClient((req) async {
          headers.add(req.headers);
          return http.Response.bytes(utf8.encode(jsonEncode(statusJson())), 200);
        }),
      );
      await client.status(accessToken: 't');
      expect(headers.single['X-Client-Version'], '2.5.1');
      expect(headers.single['X-Client-App'], 'mobile/android');
    });
    test('a version outside the pattern is not sent', () async {
      CommunityAccountClient.versionForTest = 'dev build';
      expect(await CommunityAccountClient.versionHeaders(), isEmpty);
    });
  });

  group('5 upload pause', () {
    late CommunityStore store;
    final scheduled = <Duration>[];
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = await u.openStore();
      scheduled.clear();
      UploadPause.scheduleForTest = (d) async => scheduled.add(d);
      UpdateRequirement.current.value = UpdateRequirement.unlocked;
    });
    tearDown(() async {
      UploadPause.scheduleForTest = null;
      UploadPause.current.value = null;
      await u.closeStore(store);
    });

    final now = DateTime.utc(2026, 10, 22, 5, 0);
    Map<String, Object?> ingest(Object? paused, {String? resume, String? msg}) => {
      'ingest': {'paused': paused, 'resume_at': resume, 'pause_message': msg},
    };

    test('status: paused saves with a jittered wake; missing key keeps; false clears', () async {
      expect(
        await UploadPause.applyStatus(store, ingest(true, resume: '2026-10-22T06:30:00.000Z', msg: '저장 공간'), now: now),
        'paused',
      );
      final p = (await UploadPause.read(store))!;
      final resume = DateTime.utc(2026, 10, 22, 6, 30).millisecondsSinceEpoch ~/ 1000;
      expect(p.resumeAt, resume);
      expect(p.wakeAt! - resume, inInclusiveRange(0, 120));
      expect(p.message, '저장 공간');
      expect(scheduled.single.inSeconds, inInclusiveRange(5400, 5520));
      // Restart: the stored decision is read again.
      expect(await UploadPause.isPaused(store), isTrue);
      // Missing key or a non-bool: kept.
      expect(await UploadPause.applyStatus(store, {'ingest': {'contracts': [1, 2]}}), 'unchanged');
      expect(await UploadPause.applyStatus(store, {}), 'unchanged');
      expect(await UploadPause.isPaused(store), isTrue);
      // Extended: the new resume time is scheduled.
      await UploadPause.applyStatus(store, ingest(true, resume: '2026-10-22T08:00:00.000Z'), now: now);
      expect(scheduled.length, 2);
      // Early resume by the operator.
      expect(await UploadPause.applyStatus(store, ingest(false)), 'resumed');
      expect(await UploadPause.isPaused(store), isFalse);
    });

    test('no resume time: no timer', () async {
      await UploadPause.applyStatus(store, ingest(true), now: now);
      expect((await UploadPause.read(store))!.wakeAt, isNull);
      expect(scheduled, isEmpty);
    });

    test('503 maintenance body', () async {
      final body = utf8.encode(jsonEncode({
        'error': {'code': 'maintenance', 'resume_at': '2026-10-22T06:30:00.000Z', 'pause_message': null, 'retryable': true},
      }));
      final error = UploadPause.maintenanceError(body);
      expect(error, isNotNull);
      final p = await UploadPause.applyMaintenance(store, error, now: now);
      expect(p.source, '503');
      expect(UploadPause.maintenanceError('{"error":{"code":"busy"}}'), isNull);
      expect(UploadPause.maintenanceError('x'), isNull);
    });

    test('while paused the uploader makes zero upload requests', () async {
      await capture(
        {...u.adapter('수용'), 'report_number': 'SPP-2609-8000001'},
        sourceReportId: 'R1',
        trigger: 'realtime',
        store: store,
        projectNamespace: u.kNs,
      );
      await UploadPause.applyStatus(store, ingest(true), now: now);
      var requests = 0;
      final uploader = u.makeUploader(
        store: store,
        gate: u.FakeGate(),
        tokens: u.FakeTokens(),
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 500);
        }),
      );
      for (var i = 0; i < 3; i++) {
        final r = await uploader.requestCommunityUpload('manual');
        expect(r.result, 'cooldown');
        expect(r.errorCode, 'maintenance');
      }
      expect(requests, 0);
    });

    test('a 503 maintenance answer pauses, keeps the row and does not count an attempt', () async {
      final c = await capture(
        {...u.adapter('수용'), 'report_number': 'SPP-2609-8000002'},
        sourceReportId: 'R2',
        trigger: 'realtime',
        store: store,
        projectNamespace: u.kNs,
      );
      var requests = 0;
      final uploader = u.makeUploader(
        store: store,
        gate: u.FakeGate(),
        tokens: u.FakeTokens(),
        httpClient: MockClient((_) async {
          requests++;
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'error': {'code': 'maintenance', 'message': 'x', 'retryable': true, 'retry_after_seconds': 5400, 'resume_at': '2099-01-01T00:00:00.000Z', 'pause_message': '점검'},
            })),
            503,
            headers: {'retry-after': '5400'},
          );
        }),
      );
      final r = await uploader.requestCommunityUpload('manual');
      expect(r.result, 'cooldown');
      expect(requests, 1);
      final row = (await store.db.query('outbox', where: 'event_id=?', whereArgs: [c.eventId])).single;
      expect(row['state'], 'retry_wait');
      expect(row['attempt_count'], 0);
      expect(row['last_error_code'], 'maintenance');
      expect((row['next_retry_at'] as String).startsWith('2099-01-01T00:0'), isTrue);
      expect(await UploadPause.isPaused(store), isTrue);
      // Next run: nothing is sent while paused.
      await uploader.requestCommunityUpload('manual');
      expect(requests, 1);
    });

    Future<List<String>> background(String task) async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.appMode: AppMode.standalone.name,
        AppPrefsKeys.secureStorageV10Migrated: true,
      });
      final triggers = <String>[];
      final ok = await runCommunityUploadTask(
        task,
        now: now,
        openStore: () async => store,
        verifyGate: (s, p) async => HeadlessGate.ok,
        upload: (t) async {
          triggers.add(t);
          return UploadRunResult(runId: 'r', result: 'sent');
        },
        recoveryCheck: (s, {now}) async => true,
      );
      expect(ok, isTrue);
      return triggers;
    }

    test('background: paused → no upload at all, one resume wake scheduled', () async {
      await UploadPause.applyStatus(store, ingest(true, resume: '2026-10-22T06:30:00.000Z'), now: now);
      scheduled.clear();
      expect(await background('community-upload-periodic'), isEmpty);
      expect(scheduled.single.inSeconds, inInclusiveRange(5400, 5520));
      // The resume job itself while still paused: still nothing sent.
      expect(await background(uploadResumeTaskName), isEmpty);
    });

    test('background: resumed → the resume job uploads as usual', () async {
      expect(await background(uploadResumeTaskName), contains('recovery'));
    });

    test('background: update lock → no upload', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        UpdateRequirement.prefsKey,
        jsonEncode(const UpdateRequirement(locked: true, minVersion: '2.5.1').toJson()),
      );
      final triggers = <String>[];
      await prefs.setString(AppPrefsKeys.appMode, AppMode.standalone.name);
      await prefs.setBool(AppPrefsKeys.secureStorageV10Migrated, true);
      final ok = await runCommunityUploadTask(
        'community-upload-periodic',
        now: now,
        openStore: () async => store,
        verifyGate: (s, p) async => HeadlessGate.ok,
        upload: (t) async {
          triggers.add(t);
          return UploadRunResult(runId: 'r', result: 'sent');
        },
        recoveryCheck: (s, {now}) async => true,
      );
      expect(ok, isTrue);
      expect(triggers, isEmpty);
      UpdateRequirement.current.value = UpdateRequirement.unlocked;
    });

    testWidgets('banner text with and without a resume time, message as plain text', (tester) async {
      final at = DateTime.utc(2026, 10, 22, 6, 30).millisecondsSinceEpoch ~/ 1000;
      UploadPause.current.value = UploadPause(paused: true, resumeAt: at, wakeAt: at, message: '<i>저장 공간</i>', source: 'status', savedAt: 0);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: UploadPauseBanner(now: () => now))));
      expect(find.text('서버 점검 중입니다. 신고 업로드를 잠시 멈췄고, 오후 3시 30분에 자동으로 다시 올립니다.'), findsOneWidget);
      expect(find.text('<i>저장 공간</i>'), findsOneWidget);
      UploadPause.current.value = const UploadPause(paused: true, source: 'status', savedAt: 0);
      await tester.pump();
      expect(find.text('서버 점검 중입니다. 신고 업로드를 잠시 멈췄고, 점검이 끝나면 자동으로 다시 올립니다.'), findsOneWidget);
      UploadPause.current.value = null;
      await tester.pump();
      expect(find.byKey(const Key('uploadPauseBanner')), findsNothing);
    });

    test('KST clock label', () {
      final t = DateTime.utc(2026, 10, 23, 0, 0).millisecondsSinceEpoch ~/ 1000;
      expect(kstClockLabel(t, now: now), '10월 23일 오전 9시');
      final pm = DateTime.utc(2026, 10, 22, 3, 5).millisecondsSinceEpoch ~/ 1000;
      expect(kstClockLabel(pm, now: now), '오후 12시 5분');
    });
  });

  group('7 first-run mode', () {
    setUp(() {
      setUpSecureStorage();
      SharedPreferences.setMockInitialValues({});
      FirstRunMode.choice.value = null;
    });
    tearDown(() => FirstRunMode.choice.value = null);

    test('gate mode follows the chosen mode until setup is finished', () {
      String mode() => FirstRunMode.gateMode(demo: false, configured: false, savedMode: AppMode.server);
      expect(mode(), 'unselected');
      FirstRunMode.choice.value = AppMode.standalone;
      expect(mode(), 'standalone');
      FirstRunMode.choice.value = AppMode.server;
      expect(mode(), 'server');
      expect(FirstRunMode.gateMode(demo: false, configured: true, savedMode: AppMode.standalone), 'standalone');
      expect(FirstRunMode.gateMode(demo: true, configured: false, savedMode: AppMode.server), 'demo');
    });

    test('unselected never reaches the consent step', () async {
      final server = FakeAccountServer(status: () => statusJson(consentState: 'none'));
      final g = CommunityGate(
        checkDataOwner: ownerOk,
        config: testAuthConfig(),
        auth: StubAuthService()..setPhase(CommunityAccountPhase.connected),
        accountClient: server.accountClient(),
        configStatus: () => 'ok',
        appMode: () => FirstRunMode.gateMode(demo: false, configured: false, savedMode: AppMode.server),
      );
      addTearDown(g.dispose);
      await g.refreshNow();
      expect(g.state.state, 'mode_unselected');
      expect(server.count('/status'), 0);
    });

    for (final (choice, via) in [(AppMode.standalone, 'mobile_standalone'), (AppMode.server, 'mobile_client')]) {
      testWidgets('fresh install, ${choice.name} chosen → consent via=$via', (tester) async {
        FirstRunMode.choice.value = choice;
        var consented = false;
        final server = FakeAccountServer(
          status: () => statusJson(consentState: consented ? 'active' : 'none'),
        )..onConsent = () => consented = true;
        final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
        final g = CommunityGate(
          checkDataOwner: ownerOk,
          serverGate: pcGateOk,
          config: testAuthConfig(),
          auth: auth,
          accountClient: server.accountClient(),
          configStatus: () => 'ok',
          appMode: () => FirstRunMode.gateMode(demo: false, configured: false, savedMode: AppMode.server),
        );
        addTearDown(g.dispose);
        await tester.runAsync(g.refreshNow);
        await tester.pumpWidget(MaterialApp(
          home: CommunityOnboardingScreen(gate: g, auth: auth, accountClient: server.accountClient()),
        ));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        await tester.tap(find.text('위 내용을 모두 읽고 공유에 동의합니다.'));
        await tester.pump();
        await tester.runAsync(() async {
          await tester.tap(find.text('동의하고 계속'));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();
        final consent = server.requests.where((r) => r.url.path.endsWith('/consent')).single;
        expect((jsonDecode(consent.body) as Map)['via'], via);
      });
    }
  });
}
