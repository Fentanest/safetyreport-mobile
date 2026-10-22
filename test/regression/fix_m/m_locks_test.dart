// FIX-M 회귀 시험: 필수 버전 잠금은 읽을 때마다 지금 버전과 다시 비교하고, 잠금 화면에서 카카오 로그인이 된다(R1-2, D3).
// Client 계정 불일치 잠금은 모드·서버 주소가 바뀌면 남지 않는다(R1-5).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/community/update_requirement.dart';
import 'package:safetyreport/screens/update_required_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/community_server_link_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../community/fake_account.dart';

const phoneFp = '0123456789abcdef0123456789abcdef';
const otherFp = 'fedcba9876543210fedcba9876543210';

class _LoginCounter extends StubAuthService {
  int starts = 0;
  @override
  Future<CommunityStartOutcome> startLogin() async {
    starts++;
    setPhase(CommunityAccountPhase.awaitingBrowser);
    return CommunityStartOutcome.launched;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D3 필수 버전 잠금 다시 비교', () {
    setUp(() {
      setUpSecureStorage();
      SharedPreferences.setMockInitialValues({
        UpdateRequirement.prefsKey: jsonEncode(
          const UpdateRequirement(locked: true, minVersion: '2.5.1').toJson(),
        ),
      });
      UpdateRequirement.current.value = UpdateRequirement.unlocked;
    });
    tearDown(() => UpdateRequirement.versionForTest = null);

    test('업데이트해서 min 이상이면 읽자마자 풀리고 저장값도 지운다', () async {
      UpdateRequirement.versionForTest = '2.5.1';
      expect((await UpdateRequirement.load()).locked, isFalse);
      expect(UpdateRequirement.isLocked, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(UpdateRequirement.prefsKey), isNull);
    });

    test('아직 min 미만이면 잠금 유지, 버전을 모르면(해석 불가) 마지막 판정 유지', () async {
      UpdateRequirement.versionForTest = '2.5.0';
      expect((await UpdateRequirement.load()).locked, isTrue);
      UpdateRequirement.versionForTest = 'abc';
      expect((await UpdateRequirement.load()).locked, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(UpdateRequirement.prefsKey), isNotNull);
    });

    testWidgets('잠금 화면: 카카오 세션이 없으면 카카오 로그인 버튼이 있고 누르면 로그인을 연다', (tester) async {
      final auth = _LoginCounter()..setPhase(CommunityAccountPhase.disconnected);
      await tester.pumpWidget(
        MaterialApp(
          home: UpdateRequiredScreen(
            requirement: const UpdateRequirement(
              locked: true,
              minVersion: '2.5.1',
            ),
            auth: auth,
          ),
        ),
      );
      final button = find.byKey(const Key('updateRequiredKakaoLogin'));
      expect(button, findsOneWidget);
      expect(find.text('카카오 로그인'), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      expect(auth.starts, 1);
      // 브라우저로 보낸 뒤에는 "다시 열기"로 바뀐다.
      expect(find.text('카카오 로그인 다시 열기'), findsOneWidget);
    });

    testWidgets('잠금 화면: 재인증이 필요하면 "카카오 다시 로그인", 연결돼 있으면 버튼 없음', (tester) async {
      final auth = _LoginCounter()
        ..setPhase(CommunityAccountPhase.reauthRequired);
      await tester.pumpWidget(
        MaterialApp(
          home: UpdateRequiredScreen(
            requirement: const UpdateRequirement(locked: true),
            auth: auth,
          ),
        ),
      );
      expect(find.text('카카오 다시 로그인'), findsOneWidget);
      auth.setPhase(CommunityAccountPhase.connected);
      await tester.pump();
      expect(find.byKey(const Key('updateRequiredKakaoLogin')), findsNothing);
    });
  });

  group('R1-5 Client 계정 잠금 범위', () {
    setUp(() {
      setUpSecureStorage();
      SharedPreferences.setMockInitialValues({});
    });

    CommunityGate gateFor(String Function() mode) => CommunityGate(
      checkDataOwner: ownerOk,
      serverGate: () async => CommunityGateLinkResult.success({
        'can_local': true,
        'can_enter': true,
        'kakao': true,
        'consent': {'state': 'active'},
        'account': {'fingerprint': otherFp, 'display_name': 'PC'},
      }),
      config: testAuthConfig(),
      auth: StubAuthService()..setPhase(CommunityAccountPhase.connected),
      accountClient: FakeAccountServer(
        status: () => statusJson(fingerprint: phoneFp),
      ).accountClient(),
      configStatus: () => 'ok',
      appMode: mode,
    );

    test('Client 에서 잠긴 뒤 Standalone 으로 바꾸면 메모리 잠금이 남지 않는다(동의 저장 가능)', () async {
      var mode = 'server';
      final gate = gateFor(() => mode);
      addTearDown(gate.dispose);
      await gate.refreshNow();
      expect(gate.state.state, 'client_account_mismatch');
      expect(gate.clientAccountLocked, isTrue);
      mode = 'standalone';
      gate.onAppModeChanged();
      await gate.refreshNow();
      expect(gate.state.state, isNot('client_account_mismatch'));
      expect(gate.clientAccountLocked, isFalse);
      // 같은 서버로 Client 에 돌아오면 그 서버 범위의 저장된 잠금이 다시 적용된다.
      mode = 'server';
      gate.onAppModeChanged();
      await gate.refreshNow();
      expect(gate.clientAccountLocked, isTrue);
    });

    test('서버 주소를 바꾸면(새 서버와 비교 전) 이전 서버의 잠금이 남지 않는다', () async {
      final gate = gateFor(() => 'server');
      addTearDown(gate.dispose);
      await gate.refreshNow();
      expect(gate.clientAccountLocked, isTrue);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppPrefsKeys.baseUrl, 'http://192.168.0.9:8000');
      gate.onAppModeChanged();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(gate.clientAccountLocked, isFalse);
    });
  });
}
