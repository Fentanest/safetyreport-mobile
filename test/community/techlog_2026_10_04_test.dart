// 2026-10-04 서버 기술일지에서 모바일도 같이 고친 항목의 회귀(서버·모바일 같은 규칙).
// A2-06 만족도 응답 분류, A2-08 Sunwi result, D2-03 requireFresh, D2-06 서버 후보의 자료 주인 경고.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/gate/community_gate.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/services/community_server_link_service.dart';
import 'package:safetyreport/services/standalone_api_service.dart';
import 'package:safetyreport/services/sunwi_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('A2-06 만족도 점수 응답 분류(서버 _classify_score_payload 와 같은 벡터)', () {
    final vectors = <Object?, String>{
      {'result': null}: 'empty',
      {'result': <String, dynamic>{}}: 'empty',
      {
        'result': {'STSFDG_SCORE': 5, 'STSFDG_CAUSE': '빠른 처리'},
      }: 'result',
      <String, dynamic>{}: 'unknown', // result 키 없음 — 세션 만료 등의 오류 객체
      {'error': 'session_expired'}: 'unknown',
      {'error': 'x', 'result': null}: 'unknown',
      {'result': <Object?>[]}: 'unknown',
      {'result': 'oops'}: 'unknown',
      <Object?>[]: 'unknown',
      null: 'unknown',
    };
    vectors.forEach((payload, kind) {
      test('$payload → $kind', () {
        expect(StandaloneApiService.classifyScorePayload(payload).kind, kind);
      });
    });
  });

  group('A2-08 Sunwi 지역 응답', () {
    test('명시적인 빈 목록만 0건이다', () {
      expect(SunwiService.resultListOrThrow({'result': <Object?>[]}), isEmpty);
      expect(
        SunwiService.resultListOrThrow({
          'result': [
            {'NM': 'x', 'CNT': 1},
          ],
        }),
        hasLength(1),
      );
    });
    test('result 가 없거나 목록이 아니면 실패로 다시 시도한다', () {
      for (final bad in <Object?>[
        <String, dynamic>{},
        {'error': 'x'},
        {'result': null},
        {'result': {}},
        <Object?>[],
        null,
      ]) {
        expect(
          () => SunwiService.resultListOrThrow(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  test('D2-06 서버 후보의 is_different_data_owner 를 읽는다', () {
    final status = CommunityServerStatus.tryParse({
      'state': 'confirm_required',
      'can_manage': true,
      'candidate': {
        'request_id': 'r',
        'display_name': 'B',
        'has_email': false,
        'is_different_account': false,
        'is_different_data_owner': true,
      },
    })!;
    expect(status.candidate!.isDifferentDataOwner, isTrue);
    final older = CommunityServerStatus.tryParse({
      'state': 'confirm_required',
      'candidate': {'request_id': 'r', 'display_name': 'B'},
    })!;
    expect(
      older.candidate!.isDifferentDataOwner,
      isFalse,
      reason: '필드가 없는 옛 서버는 경고 없음',
    );
  });

  group('D2-03 requireFresh 는 재검증 실패 뒤 탐색 캐시로 새 작업을 허용하지 않는다', () {
    late Directory tmp;
    late String dbPath;
    late CommunityStore store;

    setUp(() async {
      setUpSecureStorage();
      tmp = await Directory.systemTemp.createTemp('techlog_gate_test');
      dbPath = '${tmp.path}/community.db';
      store = await CommunityStore.open(
        path: dbPath,
        factory: databaseFactoryFfi,
      );
    });
    tearDown(() async {
      await CommunityStore.closeForTest(dbPath);
      await tmp.delete(recursive: true);
    });

    test('status 일시 오류 + 오래된 확인 → verification_required, 화면 상태는 유지', () async {
      var calls = 0;
      final server = FakeAccountServer(
        status: () {
          calls++;
          if (calls > 1) throw const SocketException('offline');
          return statusJson();
        },
      );
      final auth = StubAuthService()..setPhase(CommunityAccountPhase.connected);
      final gate = CommunityGate(
        checkDataOwner: ownerOk,
        config: testAuthConfig(),
        auth: auth,
        store: store,
        accountClient: server.accountClient(),
        configStatus: () => 'ok',
        appMode: () => 'standalone',
        officialAccountId: () async => 'User@Example.com',
      );
      addTearDown(gate.dispose);
      expect((await gate.refreshNow()).canEnter, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final fresh = await gate.requireFresh(maxAge: Duration.zero);
      expect(calls, 2, reason: '오래됐으니 다시 확인을 시도했다');
      expect(fresh.canEnter, isFalse);
      expect(fresh.state, 'verification_required');
      expect(fresh.reasons, contains('status_stale'));
      expect(gate.state.canEnter, isTrue, reason: '화면 이동용 10분 캐시는 그대로');
    });
  });
}
