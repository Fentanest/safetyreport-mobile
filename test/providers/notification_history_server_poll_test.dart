// SQ-B04: Client 알림 화면의 서버 결과 확인.
// 서버의 완료 신호(get_and_clear)와 기기별 결과 cursor 는 읽는 즉시 소비되므로,
// 결과를 먼저 받아 기록에 영속 저장한 뒤에만 완료 신호를 소비해야 한다. 실패는 삼키지 않고 다시 시도할 수 있어야 한다.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/notification_item.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _change(String number) => {
  'notification_kind': 'report',
  'change_type': '처리변경',
  'ID': 'id-$number',
  '신고번호': number,
  '신고명': '신고 $number',
  '처리상태': '수용',
  'synced_at': 1,
};

Future<List<String>> _savedNumbers() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final raw = prefs.getString(AppPrefsKeys.notificationsHistory);
  if (raw == null) return [];
  return (jsonDecode(raw) as List)
      .map((e) => (e as Map)['reportNumber'] as String)
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'results are durably saved before the one-shot done flag is consumed',
    () async {
      final provider = NotificationHistoryProvider();
      final calls = <String>[];
      List<String>? savedWhenDoneConsumed;
      final poll = await provider.pollServerCrawlResults(
        fetchResults: () async {
          calls.add('results');
          return [_change('R-1')];
        },
        consumeDone: () async {
          calls.add('done');
          savedWhenDoneConsumed = await _savedNumbers();
          return {'done': true, 'changed_count': 1};
        },
      );
      expect(calls, ['results', 'done']);
      expect(savedWhenDoneConsumed, ['R-1']);
      expect(poll.ok, isTrue);
      expect(poll.doneChangedCount, 1);
      expect(provider.preferredTabIndex, 1);
      // 변경이 있었으므로 "변경 없음" 완료 기록은 넣지 않는다.
      expect(
        provider.items.where((i) => i.kind == NotificationItemKind.crawl),
        isEmpty,
      );
    },
  );

  test(
    'a failed results fetch leaves the done flag for the next try',
    () async {
      final provider = NotificationHistoryProvider();
      var doneCalls = 0;
      final poll = await provider.pollServerCrawlResults(
        fetchResults: () async => throw Exception('network down'),
        consumeDone: () async {
          doneCalls++;
          return {'done': true, 'changed_count': 1};
        },
      );
      expect(poll.ok, isFalse);
      expect(poll.doneChangedCount, isNull);
      expect(doneCalls, 0);

      // 다음 확인(화면 재진입·복귀·당겨서 새로고침)에서 결과와 완료를 함께 받는다.
      final retry = await provider.pollServerCrawlResults(
        fetchResults: () async => [_change('R-2')],
        consumeDone: () async {
          doneCalls++;
          return {'done': true, 'changed_count': 1};
        },
      );
      expect(retry.ok, isTrue);
      expect(retry.doneChangedCount, 1);
      expect(doneCalls, 1);
      expect(await _savedNumbers(), ['R-2']);
    },
  );

  test('a finished crawl without changes records the 변경 없음 entry', () async {
    final provider = NotificationHistoryProvider();
    final poll = await provider.pollServerCrawlResults(
      fetchResults: () async => const [],
      consumeDone: () async => {'done': true, 'changed_count': 0},
    );
    expect(poll.doneChangedCount, 0);
    expect(provider.items.single.kind, NotificationItemKind.crawl);
  });

  test(
    'results that arrive before the crawl is marked done are kept',
    () async {
      final provider = NotificationHistoryProvider();
      final poll = await provider.pollServerCrawlResults(
        fetchResults: () async => [_change('R-3')],
        consumeDone: () async => {'done': false},
      );
      expect(poll.ok, isTrue);
      expect(poll.doneChangedCount, isNull);
      expect(await _savedNumbers(), ['R-3']);
    },
  );

  test(
    'overlapping polls (entry + resume + refresh) query the server once',
    () async {
      final provider = NotificationHistoryProvider();
      var fetches = 0;
      Future<List<Map<String, dynamic>>> fetch() async {
        fetches++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return [_change('R-4')];
      }

      Future<Map<String, dynamic>> done() async => {'done': false};
      await Future.wait([
        provider.pollServerCrawlResults(fetchResults: fetch, consumeDone: done),
        provider.pollServerCrawlResults(fetchResults: fetch, consumeDone: done),
      ]);
      expect(fetches, 1);
      expect(await _savedNumbers(), ['R-4']);
    },
  );
}
