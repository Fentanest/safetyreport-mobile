// 알림 기록의 읽음·중복 판정이 "신고번호"가 아니라 "변경 하나" 단위여야 한다 (SQ-B01),
// 기록 읽기·쓰기가 겹쳐도 새 항목·읽음 표시가 사라지지 않아야 한다 (SQ-B02),
// 한 묶음 안의 항목 ID가 겹치지 않아야 한다 (SQ-B12), 바뀐 게 없으면 다시 알리지 않는다 (SQ-P08).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/notification_item.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/prefs_inbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _change(
  String number, {
  String type = '신규',
  String status = '접수',
  Object? syncedAt,
}) => {
  'notification_kind': 'report',
  'change_type': type,
  'ID': 'id-$number',
  '신고번호': number,
  '신고명': '신고 $number',
  '처리상태': status,
  '처리기관': '기관',
  '범칙금_과태료': '',
  'synced_at': ?syncedAt,
};

Map<String, dynamic> _duplicate(
  String groupId, {
  String changeKind = 'members_changed',
  int members = 2,
}) => {
  'notification_kind': 'duplicate',
  'duplicate_change_type': changeKind,
  'change_type': '중복군 변경',
  'group_id': groupId,
  'status': 'open',
  'member_count': members,
  'representative_id': 'rep',
  '신고번호': 'D-$groupId',
};

Future<List<Map<String, dynamic>>> _saved() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final raw = prefs.getString(AppPrefsKeys.notificationsHistory);
  if (raw == null) return [];
  return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
}

List<NotificationItem> _reports(NotificationHistoryProvider p) =>
    p.items.where((i) => i.kind == NotificationItemKind.report).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SQ-B01 change identity', () {
    test(
      'opening the detail of a report does not swallow its later status change',
      () async {
        final provider = NotificationHistoryProvider();
        await provider.load(notify: false);

        // 1) 신규 알림이 기록에 들어간다.
        final first = _change('R-1', syncedAt: 1000);
        expect(provider.isPayloadRead(first), isFalse);
        await provider.addFromServerResults([first]);
        // 2) 사용자가 목록에서 상세를 연다 → 그 신고의 기존 항목만 읽음.
        await provider.markReportRead('R-1');
        expect(provider.isPayloadRead(first), isTrue);

        // 3) 다음 동기화에서 처리상태가 바뀐다 → 새 변경은 읽지 않은 것이다.
        final second = _change(
          'R-1',
          type: '처리변경',
          status: '수용',
          syncedAt: 2000,
        );
        expect(provider.isPayloadRead(second), isFalse);
        await provider.addFromServerResults([second]);

        final reports = _reports(provider);
        expect(reports, hasLength(2));
        expect(reports.first.extraData?['처리상태'], '수용');
        expect(reports.first.isRead, isFalse);
        expect(provider.unreadCount, 1);
        expect((await _saved()).length, 2);
      },
    );

    test(
      'a status change without synced_at (older servers) is still a new change',
      () async {
        final provider = NotificationHistoryProvider();
        await provider.load(notify: false);
        await provider.addFromServerResults([_change('R-2')]);
        await provider.markReportRead('R-2');
        final changed = _change('R-2', type: '처리변경', status: '불수용');
        expect(provider.isPayloadRead(changed), isFalse);
        await provider.addFromServerResults([changed]);
        expect(_reports(provider), hasLength(2));
      },
    );

    test(
      'the same change delivered twice (WebSocket history + results) is kept once',
      () async {
        final provider = NotificationHistoryProvider();
        await provider.load(notify: false);
        final change = _change('R-3', syncedAt: 3000);
        await provider.addFromServerResults([change]);
        await provider.addFromServerResults([
          Map<String, dynamic>.from(change),
        ]);
        expect(_reports(provider), hasLength(1));
      },
    );

    test(
      'history saved by an older version still answers read state per change',
      () async {
        final legacy = _change('R-4', syncedAt: 4000);
        SharedPreferences.setMockInitialValues({
          AppPrefsKeys.notificationsHistory: jsonEncode([
            {
              'id': '1700000000000_R-4',
              'kind': 'report',
              'title': 'old',
              'body': '',
              'reportNumber': 'R-4',
              'timestamp': '2026-09-01 10:00:00',
              'isRead': true,
              'extraData': legacy,
            },
          ]),
        });
        final provider = NotificationHistoryProvider();
        await provider.load(notify: false);
        expect(provider.isPayloadRead(legacy), isTrue);
        expect(
          provider.isPayloadRead(
            _change('R-4', type: '처리변경', status: '수용', syncedAt: 5000),
          ),
          isFalse,
        );
        await provider.addFromServerResults([legacy]);
        expect(_reports(provider), hasLength(1));
      },
    );

    test(
      'a later different change of the same duplicate group is recorded',
      () async {
        final provider = NotificationHistoryProvider();
        await provider.load(notify: false);
        await provider.addFromServerResults([_duplicate('G1', members: 2)]);
        await provider.addFromServerResults([_duplicate('G1', members: 3)]);
        await provider.addFromServerResults([_duplicate('G1', members: 3)]);
        expect(
          provider.items.where((i) => i.kind == NotificationItemKind.duplicate),
          hasLength(2),
        );
      },
    );
  });

  group('SQ-B02 serialized reads and writes', () {
    test('a reload racing with an add keeps the new item', () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.notificationsHistory: jsonEncode([
          {
            'id': 'a',
            'kind': 'crawl',
            'title': 'a',
            'body': '',
            'reportNumber': '',
            'timestamp': '',
            'isRead': false,
          },
        ]),
      });
      final provider = NotificationHistoryProvider();
      await provider.load(notify: false);

      final loading = provider.load();
      final adding = provider.addFromServerResults([
        _change('R-9', syncedAt: 9),
      ]);
      final loadingAgain = provider.load();
      await Future.wait([loading, adding, loadingAgain]);

      expect(provider.items.map((i) => i.reportNumber), contains('R-9'));
      expect((await _saved()).map((e) => e['reportNumber']), contains('R-9'));
    });

    test('a reload racing with markRead keeps the read flag', () async {
      final provider = NotificationHistoryProvider();
      await provider.load(notify: false);
      await provider.addFromServerResults([
        _change('R-10', syncedAt: 10),
        _change('R-11', syncedAt: 11),
      ]);
      final ids = provider.items.map((i) => i.id).toList();

      await Future.wait([
        provider.load(),
        provider.markRead(ids[0]),
        provider.load(),
        provider.markRead(ids[1]),
        provider.load(),
      ]);

      expect(provider.items.every((i) => i.isRead), isTrue);
      final reloaded = NotificationHistoryProvider();
      await reloaded.load(notify: false);
      expect(reloaded.items.every((i) => i.isRead), isTrue);
    });

    test(
      'items the service puts in the inbox while an add is saving survive',
      () async {
        final provider = NotificationHistoryProvider();
        await provider.load(notify: false);
        final prefs = await SharedPreferences.getInstance();
        final adding = provider.addFromServerResults([
          _change('R-12', syncedAt: 12),
        ]);
        await prefs.setString(
          '${PrefsInbox.history}${'5'.padLeft(15, '0')}_000001_x',
          jsonEncode([
            {
              'id': 'svc',
              'kind': 'crawl',
              'title': 'svc',
              'body': '',
              'reportNumber': '',
              'timestamp': '',
              'isRead': false,
            },
          ]),
        );
        await Future.wait([adding, provider.load()]);
        final ids = (await _saved()).map((e) => e['id']).toList();
        expect(ids, contains('svc'));
        expect(
          (await _saved()).map((e) => e['reportNumber']),
          contains('R-12'),
        );
      },
    );
  });

  group('SQ-B12 unique ids', () {
    test(
      'items of one batch get distinct ids and are marked read one by one',
      () async {
        final provider = NotificationHistoryProvider();
        await provider.load(notify: false);
        await provider.addFromServerResults([
          _change('', syncedAt: 1),
          _change('', syncedAt: 2),
          _duplicate(''),
          _duplicate(''),
        ]);
        final ids = provider.items.map((i) => i.id).toList();
        expect(ids.toSet(), hasLength(4));

        await provider.markRead(ids.first);
        expect(provider.items.where((i) => i.isRead), hasLength(1));
        expect(provider.items.first.isRead, isTrue);
      },
    );

    test('colliding ids saved by an older version are made distinct', () async {
      Map<String, dynamic> item(String body) => {
        'id': '1700000000000_',
        'kind': 'report',
        'title': body,
        'body': body,
        'reportNumber': '',
        'timestamp': '',
        'isRead': false,
      };
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.notificationsHistory: jsonEncode([
          item('one'),
          item('two'),
        ]),
      });
      final provider = NotificationHistoryProvider();
      await provider.load(notify: false);
      final ids = provider.items.map((i) => i.id).toList();
      expect(ids.toSet(), hasLength(2));
      await provider.markRead(ids[1]);
      expect(provider.items.map((i) => i.isRead), [false, true]);
    });
  });

  group('SQ-P08 unchanged reloads', () {
    test('reloading unchanged history does not notify listeners', () async {
      final provider = NotificationHistoryProvider();
      await provider.load(notify: false);
      await provider.addFromServerResults([_change('R-20', syncedAt: 20)]);
      var notified = 0;
      provider.addListener(() => notified++);
      await provider.load();
      await provider.load();
      expect(notified, 0);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '${PrefsInbox.history}${'7'.padLeft(15, '0')}_000001_y',
        jsonEncode([
          {
            'id': 'svc2',
            'kind': 'crawl',
            'title': 'svc2',
            'body': '',
            'reportNumber': '',
            'timestamp': '',
            'isRead': false,
          },
        ]),
      );
      await provider.load();
      expect(notified, 1);
      expect(provider.items.first.id, 'svc2');
    });
  });

  // main.dart _checkPendingChanges 가 쓰는 경로: 판정·추가·저장을 한 작업으로 끝낸 뒤 돌려준 것만 카드로 보이고 ack 한다.
  group('SQ-B01 pending-changes flow', () {
    test(
      'new → detail opened → status change: the change is returned for the card sheet and recorded',
      () async {
        final provider = NotificationHistoryProvider();
        final first = _change('R-30', syncedAt: 30);
        expect(await provider.recordPendingChanges([first]), [first]);
        await provider.markReportRead('R-30'); // 목록에서 상세를 연다

        // 같은 변경이 다시 오면 이미 읽은 것이므로 카드로 보이지 않는다(호출자는 ack).
        expect(await provider.recordPendingChanges([first]), isEmpty);

        final second = _change(
          'R-30',
          type: '처리변경',
          status: '수용',
          syncedAt: 31,
        );
        final shown = await provider.recordPendingChanges([
          second,
        ], preferredTabIndexIfUnread: 1);
        expect(shown, [second]);
        expect(provider.preferredTabIndex, 1);
        expect(_reports(provider), hasLength(2));
        expect(_reports(provider).first.isRead, isFalse);
        // 반환 전에 저장까지 끝났다 → 호출자가 ack 해도 잃지 않는다.
        expect((await _saved()).first['extraData']['처리상태'], '수용');
      },
    );

    test(
      'a change the service already put in the history inbox is shown once and not duplicated',
      () async {
        final change = _change('R-31', syncedAt: 40);
        SharedPreferences.setMockInitialValues({
          '${PrefsInbox.history}${'9'.padLeft(15, '0')}_000001_z': jsonEncode([
            {
              'id': '9_0_R-31_abcd1234',
              'kind': 'report',
              'title': 'svc',
              'body': '',
              'reportNumber': 'R-31',
              'timestamp': '',
              'isRead': false,
              'extraData': change,
            },
          ]),
        });
        final provider = NotificationHistoryProvider();
        final shown = await provider.recordPendingChanges([
          Map<String, dynamic>.from(change),
        ], preferredTabIndexIfUnread: 1);
        expect(shown, hasLength(1));
        expect(provider.preferredTabIndex, 1);
        expect(_reports(provider), hasLength(1));
        expect(await _saved(), hasLength(1));
      },
    );
  });
}
