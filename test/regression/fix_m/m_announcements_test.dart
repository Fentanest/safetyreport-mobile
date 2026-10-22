// FIX-M 회귀 시험: 공지 팝업이 떠 있을 때 게이트가 막히면 팝업을 닫는다(검수 의심 항목),
// 공지 링크 허용 규칙이 서버 정규식과 같다(R5-5 경계 경우).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/announcements/announcement_model.dart';
import 'package:safetyreport/announcements/announcement_presenter.dart';
import 'package:safetyreport/community/report/report_env.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../community/report/report_test_support.dart';

String _response() => jsonEncode({
  'protocol': 1,
  'announcements': [
    {
      'id': 'first-one',
      'title': '제목',
      'body': '본문',
      'primary_action': null,
      'snooze_days': 7,
      'starts_at': '2026-10-01T00:00:00.000Z',
      'ends_at': null,
      'priority': 10,
    },
  ],
  'server_time': '2026-10-22T03:00:00.000Z',
});

void main() {
  group('공지 팝업과 게이트 막힘', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AnnouncementPresenter.resetForTest();
      FakeNet(
        (_) => http.Response.bytes(utf8.encode(_response()), 200),
      ).install();
    });
    tearDown(ReportEnv.reset);

    testWidgets('팝업이 떠 있는 동안 막히면 닫히고, "닫기"로 치지 않아 다음에 다시 보인다', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );
      final allowed = ValueNotifier(true);
      Future<void> show() => AnnouncementPresenter.maybeShow(
        ctx,
        mode: 'standalone',
        openModeSwitch: () async {},
        stillAllowed: () => allowed.value,
        watch: allowed,
      );
      final first = show();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('announcement_popup')), findsOneWidget);

      allowed.value = false; // 게이트가 막힘(온보딩 화면으로 바뀜)
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('announcement_popup')), findsNothing);
      await tester.runAsync(() => first);

      // 막힌 동안에는 띄우지 않는다.
      await tester.runAsync(show);
      await tester.pump();
      expect(find.byKey(const Key('announcement_popup')), findsNothing);

      // 다시 열리면 같은 공지가 다시 보인다(닫기로 치지 않았다).
      allowed.value = true;
      final again = show();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('announcement_popup')), findsOneWidget);
      await tester.tap(find.byKey(const Key('announcement_close')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => again);
    });
  });

  test('링크 허용은 서버(SQL·Edge) 정규식과 같다: 벡터 밖 경계 경우', () {
    // R5 보고서 5번 표의 SQL/Edge 열(T=허용).
    const cases = {
      'https://github.com/Fentanest/': true,
      'https://safemap.worklazy.net?x=1': false,
      'https://safemap.worklazy.net#a': false,
      'https://play.google.com/store/apps/details?id=com.fentanest.mysafetyreport#x':
          false,
      "https://play.google.com/store/apps/details?id=com.fentanest.mysafetyreport&hl=ko&x=a'b":
          false,
      "https://github.com/Fentanest/x?q=a'b": false,
      'https://github.com/Fentanest/x(y)': false,
      'https://github.com/Fentanest/x;y': false,
      'https://github.com/Fentanest/a,b': false,
      'https://github.com/Fentanest/a|b': false,
      'https://-a.worklazy.net/': false,
      'https://a..worklazy.net/': false,
      'https://safemap.worklazy.net/한글': false,
      'https://SafeMap.worklazy.net/': false,
      'https://safemap.worklazy.net/a?b=c#d': true,
      'https://github.com/Fentanest/x?q=1#top': true,
      'https://play.google.com/store/apps/details?id=com.fentanest.mysafetyreport&hl=ko':
          true,
      'https://safemap.worklazy.net/%ED%95%9C': true,
    };
    for (final e in cases.entries) {
      expect(AnnouncementParser.linkAllowed(e.key), e.value, reason: e.key);
    }
  });
}
