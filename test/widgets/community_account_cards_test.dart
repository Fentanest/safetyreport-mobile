import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/services/community_auth_config.dart';
import 'package:safetyreport/services/community_auth_service.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/community_account_card.dart';
import 'package:safetyreport/widgets/community_server_account_card.dart';

import '../support/ui_harness.dart';

const _supabase = 'https://proj.supabase.test';
final _now = DateTime(2026, 9, 25, 10);

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

/// 가짜 Supabase(교환·사용자·로그아웃). 실제 네트워크 없음.
final _fakeSupabase = MockClient((req) async {
  switch (req.url.path) {
    case '/auth/v1/token':
      return _json({
        'access_token': 'acc-1',
        'refresh_token': 'ref-1',
        'expires_in': 3600,
        'expires_at': _now.millisecondsSinceEpoch ~/ 1000 + 3600,
      });
    case '/auth/v1/user':
      return _json({
        'id': 'user-new',
        'user_metadata': {'nickname': '아주긴카카오닉네임을가진새사용자입니다정말로길어요'},
      });
    case '/auth/v1/logout':
      return http.Response('', 204);
  }
  return http.Response('', 404);
});

CommunityAuthService _service({bool configured = true}) => CommunityAuthService(
  config: configured
      ? CommunityAuthConfig.validate(url: _supabase, key: 'sb_publishable_t')
      : CommunityAuthConfig.validate(url: '', key: ''),
  client: _fakeSupabase,
  storage: const FlutterSecureStorage(),
  launcher: (_) async => true,
  now: () => _now,
);

String _session({String state = 'active', String name = '기존연결계정'}) =>
    jsonEncode({
      'v': 1,
      'access_token': state == 'active' ? 'acc-old' : '',
      'refresh_token': state == 'active' ? 'ref-old' : '',
      'expires_at': _now.millisecondsSinceEpoch ~/ 1000 + 3600,
      'user_id': 'user-old',
      'display_name': name,
      'has_email': false,
      'connected_at': '2026-09-20T01:00:00Z',
      'state': state,
    });

Map<String, dynamic> _status(String state, {bool canManage = true}) => {
  'state': state,
  'can_manage': canManage,
  'pending': state == 'pending'
      ? {
          'request_id': 'req-1',
          'display_code': 'ABCD-2345',
          'bootstrap_url': 'https://safeauth.worklazy.net/#r=req-1&t=secret',
          'expires_at': '2026-09-25T01:10:00Z',
          'phase': 'claimed',
        }
      : null,
  'candidate': state == 'confirm_required'
      ? {
          'request_id': 'req-1',
          'display_name': '서버가확인한아주긴카카오닉네임사용자',
          'has_email': false,
          'is_different_account': true,
        }
      : null,
  'account': (state == 'connected' || state == 'confirm_required')
      ? {
          'display_name': '연결된서버계정',
          'connected_at': '2026-09-24T12:00:00Z',
          'session_state': 'active',
        }
      : null,
  'last_error': null,
  'upload_enabled': false,
};

void main() {
  late Map<String, String> secure;

  setUp(() {
    secure = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(secure);
  });

  group('Standalone 커뮤니티 계정 카드', () {
    final cases = <String, (void Function(), bool, List<String>)>{
      '설정되지 않음': (() {}, false, ['설정되지 않음']),
      '연결 안 됨': (
        () {},
        true,
        ['연결 안 됨', '카카오 계정으로 연결', '계정 연결만으로 신고 데이터가 업로드되지는 않습니다.'],
      ),
      '연결됨': (
        () => secure[CommunityAuthService.sessionKey] = _session(),
        true,
        ['연결됨', '기존연결계정', '연결 해제'],
      ),
      '다시 로그인 필요': (
        () => secure[CommunityAuthService.sessionKey] = _session(
          state: 'reauth_required',
        ),
        true,
        ['다시 로그인 필요', '다시 로그인'],
      ),
      '브라우저 대기': (
        () => secure[CommunityAuthService.pendingLoginKey] = jsonEncode({
          'v': 1,
          'attempt_id': 'a',
          'verifier': 'v' * 43,
          'started_at': _now.millisecondsSinceEpoch,
        }),
        true,
        ['브라우저 로그인 대기', '다시 시작'],
      ),
    };

    for (final entry in cases.entries) {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('${entry.key} · ${brightness.name} · x$scale', (
            tester,
          ) async {
            final (seed, configured, texts) = entry.value;
            seed();
            final svc = _service(configured: configured);
            final errors = await pumpThemed(
              tester,
              CommunityAccountCard(service: svc),
              brightness: brightness,
              textScale: scale,
              width: 320,
            );
            await tester.pumpAndSettle();
            expect(errors, isEmpty, reason: describeErrors(errors));
            expect(tester.takeException(), isNull);
            for (final t in texts) {
              expect(find.textContaining(t), findsWidgets, reason: t);
            }
            if (!configured) {
              expect(find.text('카카오 계정으로 연결'), findsNothing);
            }
          });
        }
      }
    }

    testWidgets('로그인 복귀 → 전역 확인 창 → "이 계정으로 연결" 로 저장 (교체 경고)', (tester) async {
      secure[CommunityAuthService.sessionKey] = _session();
      final svc = _service();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Brightness.dark),
          navigatorKey: communityAuthNavigatorKey,
          scaffoldMessengerKey: communityAuthMessengerKey,
          builder: (context, child) =>
              CommunityAuthPrompt(service: svc, child: child!),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(2.0),
            ),
            child: Scaffold(
              body: ListView(children: [CommunityAccountCard(service: svc)]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await svc.startLogin();
        await svc.handleCallbackLink(
          'com.fentanest.mysafetyreport://auth/callback?code=0b6b2b1e-6f1c-4b8e-9d56-1d5e2f3a4b5c',
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('이 계정으로 연결할까요?'), findsOneWidget);
      expect(find.textContaining('기존연결계정 계정이 이 계정으로 바뀝니다'), findsWidgets);
      expect(tester.takeException(), isNull);
      // 확인 창의 버튼.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('이 계정으로 연결'),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        (jsonDecode(secure[CommunityAuthService.sessionKey]!)
            as Map)['user_id'],
        'user-new',
      );
      expect(svc.state.value.phase, CommunityAccountPhase.connected);
    });

    testWidgets('확인 창은 x2.0 · 320폭에서 넘치지 않는다', (tester) async {
      for (final b in Brightness.values) {
        final errors = await pumpThemed(
          tester,
          const CommunityConfirmDialog(
            displayName: '아주긴카카오닉네임을가진새사용자입니다정말로길어요',
            replacingName: '기존연결계정',
          ),
          brightness: b,
          textScale: 2.0,
          width: 320,
        );
        expect(errors, isEmpty, reason: describeErrors(errors));
      }
    });
  });

  group('Client 서버의 커뮤니티 계정 카드', () {
    MockClient serverWith(Map<String, dynamic> status) =>
        MockClient((req) async {
          expect(req.url.host, 'nas.example.test', reason: 'Supabase 호출 금지');
          return _json({'data': status});
        });

    final cases = <String, (Map<String, dynamic>, List<String>)>{
      'disconnected': (_status('disconnected'), ['연결 안 됨', '카카오 계정으로 연결']),
      'pending': (
        _status('pending'),
        ['연결 대기', 'ABCD-2345', '브라우저에서 비교코드가 같은지 확인하세요.', '요청 취소'],
      ),
      'confirm_required': (
        _status('confirm_required'),
        ['연결된 서버를 확인해 주세요.', '서버가확인한아주긴카카오닉네임사용자', '이 계정으로 연결', '바뀝니다'],
      ),
      'connected': (_status('connected'), ['연결됨', '연결된서버계정', '연결 해제']),
      'reauth_required': (_status('reauth_required'), ['다시 로그인 필요', '다시 연결']),
      'no permission': (
        _status('disconnected', canManage: false),
        ['관리 권한을 허용해야 합니다'],
      ),
    };

    for (final entry in cases.entries) {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('${entry.key} · ${brightness.name} · x$scale', (
            tester,
          ) async {
            final (status, texts) = entry.value;
            final errors = await pumpThemed(
              tester,
              CommunityServerAccountCard(
                baseUrl: 'https://nas.example.test',
                apiKey: 'k',
                client: serverWith(status),
                pollInterval: const Duration(hours: 1),
              ),
              brightness: brightness,
              textScale: scale,
              width: 320,
            );
            await tester.pump();
            await tester.pump();
            expect(errors, isEmpty, reason: describeErrors(errors));
            expect(tester.takeException(), isNull);
            for (final t in texts) {
              expect(find.textContaining(t), findsWidgets, reason: t);
            }
            // 1회용 연결 링크는 화면에 글자로 나오지 않는다.
            expect(find.textContaining('safeauth/#r='), findsNothing);
          });
        }
      }
    }

    testWidgets('403 → 권한 안내, 404 → 미지원 안내, 오프라인 → 시작 실패 안내', (tester) async {
      Future<void> pumpWith(MockClient c) async {
        await pumpThemed(
          tester,
          CommunityServerAccountCard(
            key: UniqueKey(),
            baseUrl: 'https://nas.example.test',
            apiKey: 'k',
            client: c,
          ),
          brightness: Brightness.light,
          textScale: 2.0,
          width: 320,
        );
        await tester.pump();
        await tester.pump();
      }

      await pumpWith(
        MockClient(
          (_) async => _json({
            'detail': '서버 관리자 화면에서 이 기기의 커뮤니티 계정 관리 권한을 허용해야 합니다.',
            'code': 'permission_required',
          }, 403),
        ),
      );
      expect(find.textContaining('관리 권한을 허용해야 합니다'), findsOneWidget);

      await pumpWith(MockClient((_) async => _json({'detail': 'x'}, 404)));
      expect(find.text('서버가 이 기능을 아직 지원하지 않습니다.'), findsOneWidget);

      // 상태는 읽혔지만 시작 요청 때 서버가 꺼짐 → Standalone 으로 바꾸지 않고 오류만.
      var calls = 0;
      await pumpWith(
        MockClient((req) async {
          calls++;
          if (req.url.path.endsWith('/status')) {
            return _json({'data': _status('disconnected')});
          }
          throw http.ClientException('offline');
        }),
      );
      await tester.tap(find.text('카카오 계정으로 연결'));
      await tester.pump();
      await tester.pump();
      expect(find.text('서버에 연결할 수 없어 요청을 시작하지 못했습니다.'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('pending 동안 약 3초마다 상태를 다시 읽고, connected 가 되면 멈춘다', (
      tester,
    ) async {
      var n = 0;
      final client = MockClient((req) async {
        n++;
        return _json({'data': _status(n < 3 ? 'pending' : 'connected')});
      });
      await pumpThemed(
        tester,
        CommunityServerAccountCard(
          baseUrl: 'https://nas.example.test',
          apiKey: 'k',
          client: client,
        ),
        brightness: Brightness.dark,
      );
      await tester.pump();
      expect(n, 1);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(n, 2);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(n, 3);
      expect(find.text('연결됨'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(n, 3);
    });
  });
}
