import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/notify/user_action_notifier.dart';
import 'package:safetyreport/community/report/report_env.dart';
import 'package:safetyreport/widgets/user_action_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<Map<String, Object?>> shown;
  late DateTime clock;
  late bool granted;

  Future<void> eval({
    String? reason,
    bool manual = false,
    bool blocked = false,
    int stale = 0,
    bool update = false,
  }) => UserActionNotifier.evaluate(
    backfillReason: reason,
    officialLoginManual: manual,
    optimizeBlockedInBackground: blocked,
    staleHolds: stale,
    updateRequired: update,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    shown = [];
    clock = DateTime.utc(2026, 10, 22, 3);
    granted = true;
    ReportEnv.now = () => clock;
    UserActionNotifier.permissionGranted = () async => granted;
    UserActionNotifier.show = (args) async => shown.add(args);
    UserActionNotifier.items.value = const [];
  });
  tearDown(() {
    ReportEnv.reset();
  });

  test('사유별 문구(8절 표)와 누르면 갈 이벤트 이름', () async {
    await eval(
      reason: 'official_login_required',
      manual: true,
      blocked: true,
      stale: 3,
      update: true,
    );
    final bodies = shown.map((s) => s['body']).toList();
    expect(bodies, [
      '앱을 업데이트해 주세요. 업데이트하면 신고 공유를 이어 갑니다.',
      '안전신문고 로그인이 필요합니다. 앱에서 다시 로그인해 주세요.',
      '30일 넘게 올리지 못한 신고가 3건 있습니다. 앱에서 확인해 주세요.',
      '신고 공유를 이어 가려면 앱을 한 번 열어 주세요.',
    ]);
    expect(shown.map((s) => s['event_type']), [
      'user_action_update_required',
      'user_action_official_login_required',
      'user_action_stale_holds',
      'user_action_optimize_blocked_background',
    ]);
  });

  test('같은 사유는 기기 KST 날짜당 1번, 다음 날 다시, 다른 사유는 따로', () async {
    await eval(stale: 2);
    await eval(stale: 2);
    expect(shown, hasLength(1));
    clock = clock.add(const Duration(hours: 3)); // KST 같은 날
    await eval(stale: 2);
    expect(shown, hasLength(1));
    await eval(stale: 2, blocked: true); // 새 사유만 추가
    expect(shown, hasLength(2));
    clock = DateTime.utc(2026, 10, 22, 16); // KST 다음 날
    await eval(stale: 2, blocked: true);
    expect(shown, hasLength(4));
  });

  test('official_login_required 는 수동 표시가 있을 때만', () async {
    await eval(reason: 'official_login_required', manual: false);
    await eval(reason: 'official_login_retry', manual: true);
    expect(shown, isEmpty);
    expect(UserActionNotifier.items.value, isEmpty);
  });

  test('알림 권한이 없으면 알림 없이 앱 안 안내 상태만 남기고, 권한 요청도 하지 않는다', () async {
    granted = false;
    await eval(stale: 4);
    expect(shown, isEmpty);
    expect(UserActionNotifier.items.value, [
      const UserActionItem('stale_holds', count: 4),
    ]);
    // 저장된 상태는 다른 isolate/다음 실행에서 읽을 수 있다.
    UserActionNotifier.items.value = const [];
    final loaded = await UserActionNotifier.load();
    expect(loaded.single.reason, 'stale_holds');
    expect(loaded.single.count, 4);
    // 권한이 생기면 그날 처음으로 알린다(권한 없을 때는 알린 날짜로 치지 않는다).
    granted = true;
    await eval(stale: 4);
    expect(shown, hasLength(1));
  });

  test('알림 표시가 실패하면 오늘 알린 것으로 치지 않는다', () async {
    UserActionNotifier.show = (_) async => throw Exception('no channel');
    await eval(blocked: true);
    UserActionNotifier.show = (args) async => shown.add(args);
    await eval(blocked: true);
    expect(shown, hasLength(1));
  });

  testWidgets('상단 안내: 같은 문장과 버튼, 업데이트는 그리지 않음', (tester) async {
    var logins = 0;
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserActionBanner(
            onLogin: () => logins++,
            onRetry: () => retries++,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('user_action_banner_text')), findsNothing);

    UserActionNotifier.items.value = const [
      UserActionItem('update_required'),
      UserActionItem('official_login_required'),
    ];
    await tester.pump();
    expect(find.text('안전신문고 로그인이 필요합니다. 앱에서 다시 로그인해 주세요.'), findsOneWidget);
    await tester.tap(find.text('로그인'));
    expect(logins, 1);

    UserActionNotifier.items.value = const [
      UserActionItem('stale_holds', count: 2),
    ];
    await tester.pump();
    expect(
      find.text('30일 넘게 올리지 못한 신고가 2건 있습니다. 앱에서 확인해 주세요.'),
      findsOneWidget,
    );
    await tester.tap(find.text('다시 시도'));
    expect(retries, 1);

    UserActionNotifier.items.value = const [
      UserActionItem('optimize_blocked_background'),
    ];
    await tester.pump();
    expect(find.text('앱을 열어 두면 신고 정리를 마치고 공유를 이어 갑니다.'), findsOneWidget);
    expect(find.byKey(const Key('user_action_banner_button')), findsNothing);

    UserActionNotifier.items.value = const [UserActionItem('update_required')];
    await tester.pump();
    expect(find.byKey(const Key('user_action_banner_text')), findsNothing);
  });
}
