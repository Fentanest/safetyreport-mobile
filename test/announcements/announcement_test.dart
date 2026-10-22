import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/announcements/announcement_model.dart';
import 'package:safetyreport/announcements/announcement_presenter.dart';
import 'package:safetyreport/community/report/report_env.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../community/report/report_test_support.dart';

Map<String, Object?> ann(
  String id, {
  Object? action,
  int snooze = 7,
  int priority = 10,
  String title = '제목',
  String body = '본문',
}) => {
  'id': id,
  'title': title,
  'body': body,
  'primary_action': action,
  'snooze_days': snooze,
  'starts_at': '2026-10-01T00:00:00.000Z',
  'ends_at': null,
  'priority': priority,
};

String response(List<Map<String, Object?>> list) => jsonEncode({
  'protocol': 1,
  'announcements': list,
  'server_time': '2026-10-22T03:00:00.000Z',
});

http.Response okJson(String body) =>
    http.Response.bytes(utf8.encode(body), 200);

void main() {
  group('계약 사본 contracts/app-announcements', () {
    test('사본이 MANIFEST.sha256 과 같다(지도 정본과 어긋나면 실패)', () {
      const dir = 'contracts/app-announcements';
      final listed = <String>{};
      for (final line in File('$dir/MANIFEST.sha256').readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final m = RegExp(r'^([0-9a-f]{64})  (.+)$').firstMatch(line)!;
        listed.add(m.group(2)!);
        expect(
          sha256.convert(File('$dir/${m.group(2)}').readAsBytesSync()).toString(),
          m.group(1),
          reason: m.group(2),
        );
      }
      final present = Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.substring(dir.length + 1))
          .where((p) => p != 'MANIFEST.sha256')
          .toSet();
      expect(present, listed, reason: 'MANIFEST 에 없는 파일이나 빠진 파일');
    });
  });

  group('허용 링크 (links.json 벡터)', () {
    final vectors =
        jsonDecode(
              File(
                'contracts/app-announcements/vectors/links.json',
              ).readAsStringSync(),
            )
            as Map;
    test('벡터와 같은 결과', () {
      for (final c in vectors['cases'] as List) {
        expect(
          AnnouncementParser.linkAllowed(c['url'] as String),
          c['allowed'],
          reason: c['url'] as String,
        );
      }
    });
  });

  group('응답 검사', () {
    test('정상 응답은 우선순위 큰 것 먼저', () {
      final list = AnnouncementParser.response(
        jsonDecode(
          response([ann('aaa', priority: 1), ann('bbb', priority: 9)]),
        ),
      )!;
      expect(list.map((a) => a.id), ['bbb', 'aaa']);
    });

    test('틀린 항목만 버리고 나머지는 남긴다: id·제목 40자·본문 600자·제어문자·키 추가', () {
      final list = AnnouncementParser.response(
        jsonDecode(
          response([
            ann('Bad_Id'),
            ann('long-title', title: '가' * 41),
            ann('good-one', title: '가' * 40, body: '가' * 600),
          ]),
        ),
      )!;
      expect(list.map((a) => a.id), ['good-one']);
      expect(AnnouncementParser.item(ann('ctrl-body', body: '가\r\n나')), isNull);
      expect(
        AnnouncementParser.item(ann('ctrl-body', body: '가\u0001나')),
        isNull,
      );
      expect(
        AnnouncementParser.item(ann('long-body', body: '가' * 601)),
        isNull,
      );
      expect(
        AnnouncementParser.item({...ann('extra-key'), 'html': 'x'}),
        isNull,
      );
      expect(AnnouncementParser.item(ann('line-ok', body: '가\n나')), isNotNull);
    });

    test('응답이 4개 이상이거나 protocol·모양이 틀리면 전체를 쓰지 않는다', () {
      Object? j(Map<String, Object?> m) => jsonDecode(jsonEncode(m));
      final base = {
        'protocol': 1,
        'announcements': [ann('aaa')],
        'server_time': '2026-10-22T03:00:00.000Z',
      };
      expect(AnnouncementParser.response(j(base)), isNotNull);
      expect(AnnouncementParser.response(j({...base, 'protocol': 2})), isNull);
      expect(AnnouncementParser.response(j({...base, 'extra': 1})), isNull);
      expect(
        AnnouncementParser.response(
          j({
            ...base,
            'announcements': [ann('aaa'), ann('bbb'), ann('ccc'), ann('ddd')],
          }),
        ),
        isNull,
      );
      expect(AnnouncementParser.response('not json object'), isNull);
    });

    test('버튼: 허용 링크·open_mode_switch 만, 그 밖은 버튼만 숨기고 공지는 둔다', () {
      AnnouncementAction? a(Object? action) =>
          AnnouncementParser.item(ann('aaa', action: action))!.action;
      expect(
        a({'label': '바꾸기', 'app_action': 'open_mode_switch'})!.appAction,
        'open_mode_switch',
      );
      expect(a({'label': '바꾸기', 'app_action': 'delete_everything'}), isNull);
      expect(
        a({'label': '열기', 'url': 'https://safemap.worklazy.net/'})!.url,
        'https://safemap.worklazy.net/',
      );
      expect(a({'label': '열기', 'url': 'https://evil.example/'}), isNull);
      expect(a({'label': '열기', 'url': 'javascript:alert(1)'}), isNull);
      expect(a(null), isNull);
      // 모양이 아예 틀리면 항목을 버린다.
      expect(
        AnnouncementParser.item(ann('aaa', action: {'label': 'x'})),
        isNull,
      );
      expect(
        AnnouncementParser.item(
          ann(
            'aaa',
            action: {
              'label': 'x'.padRight(21, 'x'),
              'url': 'https://safemap.worklazy.net/',
            },
          ),
        ),
        isNull,
      );
    });
  });

  group('표시', () {
    late FakeNet net;
    late List<Uri> launched;
    var switched = 0;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AnnouncementPresenter.resetForTest();
      switched = 0;
      launched = [];
      AnnouncementPresenter.launcher = (u) async {
        launched.add(u);
        return true;
      };
      net = FakeNet((_) => okJson(response([ann('first-one')])));
      net.install();
    });
    tearDown(ReportEnv.reset);

    Future<BuildContext> pumpHost(WidgetTester tester) async {
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
      return ctx;
    }

    Future<void> start(
      WidgetTester tester,
      BuildContext ctx, {
      String mode = 'client',
    }) async {
      _pending.add(
        AnnouncementPresenter.maybeShow(
          ctx,
          mode: mode,
          openModeSwitch: () async => switched++,
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('요청: 쿼리 4개와 apikey 헤더만(토큰 없음)', (tester) async {
      final ctx = await pumpHost(tester);
      await start(tester, ctx);
      final r = net.requests.single;
      expect(r.method, 'GET');
      expect(r.url.path, '/functions/v1/app-announcements');
      expect(r.url.queryParameters, {
        'app': 'mobile',
        'mode': 'client',
        'platform': 'android',
        'version': '2.5.1',
      });
      expect(r.headers.keys.map((k) => k.toLowerCase()), contains('apikey'));
      expect(
        r.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(find.byKey(const Key('announcement_popup')), findsOneWidget);
      await tester.tap(find.byKey(const Key('announcement_close')));
      await tester.pumpAndSettle();
      await tester.runAsync(_drain);
    });

    testWidgets('실패(네트워크·4xx·5xx·형식 이상)면 팝업이 없고 6시간 안에는 다시 가져오지 않는다', (
      tester,
    ) async {
      final ctx = await pumpHost(tester);
      for (final h in <http.Response Function(http.Request)>[
        (_) => http.Response('{}', 500),
        (_) => http.Response('{}', 404),
        (_) => http.Response('not json', 200),
        (_) => throw const SocketException('down'),
      ]) {
        SharedPreferences.setMockInitialValues({});
        AnnouncementPresenter.resetForTest();
        net.requests.clear();
        net.handler = h;
        await tester.runAsync(
          () => AnnouncementPresenter.maybeShow(
            ctx,
            mode: 'client',
            openModeSwitch: () async {},
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('announcement_popup')), findsNothing);
        expect(net.requests, hasLength(1));
        // 6시간 안: 다시 요청하지 않고 팝업도 없음.
        net.advance(const Duration(hours: 5, minutes: 59));
        await tester.runAsync(
          () => AnnouncementPresenter.maybeShow(
            ctx,
            mode: 'client',
            openModeSwitch: () async {},
          ),
        );
        expect(net.requests, hasLength(1));
        expect(find.byKey(const Key('announcement_popup')), findsNothing);
        // 6시간 뒤: 다시 시도.
        net.advance(const Duration(minutes: 2));
        await tester.runAsync(
          () => AnnouncementPresenter.maybeShow(
            ctx,
            mode: 'client',
            openModeSwitch: () async {},
          ),
        );
        expect(net.requests, hasLength(2));
        net.advance(const Duration(hours: 7));
      }
    });

    testWidgets('한 번에 하나, 닫으면 다음 것. 본문은 평문(HTML 그대로)', (tester) async {
      net.handler = (_) => okJson(
        response([
          ann(
            'first-one',
            title: '첫째',
            body: '<b>굵게</b> **마크다운**\n둘째 줄',
            priority: 9,
          ),
          ann('second-one', title: '둘째', priority: 1),
        ]),
      );
      final ctx = await pumpHost(tester);
      await start(tester, ctx);
      expect(find.text('첫째'), findsOneWidget);
      expect(find.text('둘째'), findsNothing);
      expect(find.text('<b>굵게</b> **마크다운**\n둘째 줄'), findsOneWidget);
      expect(find.text('일주일 동안 보지 않기'), findsOneWidget);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(find.text('둘째'), findsOneWidget);
      expect(find.text('첫째'), findsNothing);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('announcement_popup')), findsNothing);
      await tester.runAsync(_drain);
    });

    testWidgets('일주일 동안 보지 않기: 7일 숨김, 7일 뒤 다시, 닫기는 이번 실행만', (tester) async {
      final ctx = await pumpHost(tester);
      await start(tester, ctx);
      await tester.tap(find.text('일주일 동안 보지 않기'));
      await tester.pumpAndSettle();
      await tester.runAsync(_drain);
      final prefs = await SharedPreferences.getInstance();
      final until = prefs.getInt('app_announcement_snooze.first-one')!;
      expect(
        until,
        net.clock.add(const Duration(days: 7)).millisecondsSinceEpoch,
      );

      // 6시간 뒤(다시 가져옴)에도, 6일 23시간 뒤에도 안 뜬다.
      AnnouncementPresenter.resetForTest();
      net.advance(const Duration(hours: 7));
      await start(tester, ctx);
      expect(find.byKey(const Key('announcement_popup')), findsNothing);
      await tester.runAsync(_drain);
      net.advance(const Duration(days: 6, hours: 15));
      await start(tester, ctx);
      expect(find.byKey(const Key('announcement_popup')), findsNothing);
      await tester.runAsync(_drain);

      // 7일이 지나면 다시 뜨고, 지난 만료 값은 지워진다.
      net.advance(const Duration(hours: 3));
      await start(tester, ctx);
      expect(find.byKey(const Key('announcement_popup')), findsOneWidget);
      expect(prefs.getInt('app_announcement_snooze.first-one'), isNull);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tester.runAsync(_drain);

      // 닫기만 했으면 같은 실행에서는 다시 안 뜨지만(메모리), 다음 실행(메모리 초기화)에서는 캐시로 다시 뜬다.
      await start(tester, ctx);
      expect(find.byKey(const Key('announcement_popup')), findsNothing);
      await tester.runAsync(_drain);
      AnnouncementPresenter.resetForTest();
      net.requests.clear();
      await start(tester, ctx);
      expect(find.byKey(const Key('announcement_popup')), findsOneWidget);
      expect(net.requests, isEmpty, reason: '6시간 안이라 새로 가져오지 않고 캐시를 쓴다');
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tester.runAsync(_drain);
    });

    testWidgets('snooze_days 에 따라 버튼 문구가 달라진다(0 이면 없음)', (tester) async {
      for (final (days, label) in [(3, '3일 동안 보지 않기'), (0, null)]) {
        SharedPreferences.setMockInitialValues({});
        AnnouncementPresenter.resetForTest();
        net.advance(const Duration(hours: 7));
        net.handler = (_) => okJson(response([ann('first-one', snooze: days)]));
        final ctx = await pumpHost(tester);
        await start(tester, ctx);
        if (label != null) {
          expect(find.text(label), findsOneWidget);
        } else {
          expect(find.byKey(const Key('announcement_snooze')), findsNothing);
        }
        expect(find.text('닫기'), findsOneWidget);
        await tester.tap(find.text('닫기'));
        await tester.pumpAndSettle();
        await tester.runAsync(_drain);
      }
    });

    testWidgets('open_mode_switch 는 콜백을 열고, 모르는 app_action·허용 밖 링크는 버튼이 없다', (
      tester,
    ) async {
      net.handler = (_) => okJson(
        response([
          ann(
            'first-one',
            action: {'label': '지금 바꾸기', 'app_action': 'open_mode_switch'},
          ),
        ]),
      );
      final ctx = await pumpHost(tester);
      await start(tester, ctx);
      await tester.tap(find.text('지금 바꾸기'));
      await tester.pumpAndSettle();
      await tester.runAsync(_drain);
      expect(switched, 1);

      for (final action in [
        {'label': '실행', 'app_action': 'wipe'},
        {'label': '열기', 'url': 'https://evil.example/'},
      ]) {
        SharedPreferences.setMockInitialValues({});
        AnnouncementPresenter.resetForTest();
        net.advance(const Duration(hours: 7));
        net.handler = (_) =>
            okJson(response([ann('first-one', action: action)]));
        await start(tester, ctx);
        expect(find.byKey(const Key('announcement_popup')), findsOneWidget);
        expect(find.byKey(const Key('announcement_primary')), findsNothing);
        await tester.tap(find.text('닫기'));
        await tester.pumpAndSettle();
        await tester.runAsync(_drain);
      }
      expect(switched, 1);
      expect(launched, isEmpty);
    });

    testWidgets('허용 링크 버튼은 외부 브라우저로 연다', (tester) async {
      net.handler = (_) => okJson(
        response([
          ann(
            'first-one',
            action: {'label': '자세히', 'url': 'https://safemap.worklazy.net/'},
          ),
        ]),
      );
      final ctx = await pumpHost(tester);
      await start(tester, ctx);
      await tester.tap(find.text('자세히'));
      await tester.pumpAndSettle();
      await tester.runAsync(_drain);
      expect(launched.single.toString(), 'https://safemap.worklazy.net/');
    });

    testWidgets('모르는 모드면 요청하지 않는다', (tester) async {
      final ctx = await pumpHost(tester);
      await tester.runAsync(
        () => AnnouncementPresenter.maybeShow(
          ctx,
          mode: 'server',
          openModeSwitch: () async {},
        ),
      );
      expect(net.requests, isEmpty);
    });
  });
}

final List<Future<void>> _pending = [];
Future<void> _drain() async {
  final copy = List<Future<void>>.of(_pending);
  _pending.clear();
  await Future.wait(copy);
}
