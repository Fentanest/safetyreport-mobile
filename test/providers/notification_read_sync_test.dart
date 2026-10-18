// 어느 경로로 읽든(상세 시트·알림 기록·푸시 탭) 그 신고·중복군의 시스템 푸시를 함께 지운다(2026-10-18).
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/notification_item.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/services/system_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _report(String number) => {
  'notification_kind': 'report',
  'change_type': '처리변경',
  'ID': 'id-$number',
  '신고번호': number,
  '신고명': '신고 $number',
  '처리상태': '수용',
  'synced_at': 1000,
};

Map<String, dynamic> _duplicate(String groupId) => {
  'notification_kind': 'duplicate',
  'duplicate_change_type': 'members_changed',
  'change_type': '중복군 변경',
  'group_id': groupId,
  'status': 'open',
  'member_count': 2,
  'representative_id': 'rep',
  '신고번호': 'D-$groupId',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<String, Object?>> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    SystemNotifications.invoker = (args) async => calls.add(args);
  });

  Future<NotificationHistoryProvider> provider() async {
    final p = NotificationHistoryProvider();
    await p.load(notify: false);
    await p.addFromServerResults([
      _report('r-1'),
      _report('R-2'),
      _duplicate('g-1'),
    ]);
    calls.clear();
    return p;
  }

  test(
    'opening a report detail cancels that report push (normalized)',
    () async {
      final p = await provider();
      await p.markReportRead(' r-1 ');
      expect(calls.single['report_numbers'], ['R-1']);
      expect(calls.single['all'], isFalse, reason: '아직 읽지 않은 기록이 남음');
    },
  );

  test('a report missing from history still has its push cancelled', () async {
    final p = await provider();
    await p.markReportRead('R-404');
    expect(calls.single['report_numbers'], ['R-404']);
  });

  test(
    'reading one history item cancels its report or duplicate push',
    () async {
      final p = await provider();
      final dup = p.items.firstWhere(
        (i) => i.kind == NotificationItemKind.duplicate,
      );
      await p.markRead(dup.id);
      expect(calls.single['group_ids'], ['g-1']);
      final report = p.items.firstWhere((i) => i.reportNumber == 'R-2');
      await p.markRead(report.id);
      expect(calls.last['report_numbers'], ['R-2']);
    },
  );

  test('duplicate push tap marks that group read and cancels it', () async {
    final p = await provider();
    expect(p.isPayloadRead(_duplicate('g-1')), isFalse);
    await p.markPayloadRead(_duplicate('g-1'));
    expect(p.isPayloadRead(_duplicate('g-1')), isTrue);
    expect(calls.single['group_ids'], ['g-1']);
  });

  test('when every item is read all result pushes are cleared', () async {
    final p = await provider();
    await p.markReportRead('R-1');
    await p.markReportRead('R-2');
    expect(calls.last['all'], isFalse);
    await p.markDuplicateGroupRead('g-1');
    expect(calls.last['all'], isTrue, reason: '마지막 하나까지 읽음');
  });

  test('mark all read and clear all cancel every result push', () async {
    final p = await provider();
    await p.markAllRead();
    expect(calls.single['all'], isTrue);
    calls.clear();
    await p.clearAll();
    expect(calls.single['all'], isTrue);
  });
}
