// 변경 알림의 처리기관을 목록·통계와 같은 현행 표시명으로 보인다(2026-10-18).
// 같은 서울강서경찰서가 부서코드 1810043(본서)·1814605(경비교통과)·1810341(교통과)로 들어온다. 목록은
// registry 로 한 이름을 보였지만 변경 Map(서버 crawl_changes·앱 reportToChangeMap)에는 코드가 없어
// 알림 카드·알림 기록 본문·로컬 푸시에 원문(…경비교통과)이 그대로 나갔다.
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/notification_item.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/services/agency_registry.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _raw = {
  '1814605': '경찰청 서울특별시경찰청 서울강서경찰서 경비교통과',
  '1810341': '경찰청 서울특별시경찰청 서울강서경찰서 교통과',
  '1810043': '경찰청 서울특별시경찰청 서울강서경찰서',
};
const _current = '서울특별시경찰청 서울강서경찰서';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('registry loaded', () {
    setUpAll(() async {
      AgencyRegistry.testInject(null);
      await AgencyRegistry.ensureLoaded();
    });
    tearDownAll(() => AgencyRegistry.testInject(null));

    test('three Gangseo department codes show one current name', () {
      for (final entry in _raw.entries) {
        final r = {'처리기관': entry.value, '처리기관코드': entry.key};
        expect(changeMapAgencyDisplay(r), _current, reason: entry.key);
        expect(r['처리기관'], entry.value, reason: '원문 값은 그대로');
      }
    });

    test('older payload without code falls back to server current name, then raw', () {
      expect(
        changeMapAgencyDisplay({
          '처리기관': '어딘가구청 교통과',
          'agency_name_current': '어딘가구청',
        }),
        '어딘가구청',
      );
      expect(changeMapAgencyDisplay({'처리기관': '어딘가구청 교통과'}), '어딘가구청 교통과');
      expect(changeMapAgencyDisplay({}), '');
    });

    test('app change map carries the source agency code', () {
      final report = Report.fromJson({
        'ID': '90000001',
        '처리기관': _raw['1814605'],
        '처리기관코드': '1814605',
      });
      final map = SyncEngine.reportToChangeMap(report, ChangeType.newReport);
      expect(map['처리기관코드'], '1814605');
      expect(changeMapAgencyDisplay(map), _current);
    });

    test('notification history body shows the current name', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = NotificationHistoryProvider();
      await provider.load(notify: false);
      await provider.addFromServerResults([
        {
          'notification_kind': 'report',
          'change_type': '처리변경',
          'ID': '90000001',
          '신고번호': 'SPP-TEST-0001',
          '신고명': '교통위반',
          '처리상태': '불수용',
          '처리기관': _raw['1814605'],
          '처리기관코드': '1814605',
          '범칙금_과태료': '',
          'synced_at': 1000,
        },
      ]);
      final item = provider.items.firstWhere(
        (i) => i.kind == NotificationItemKind.report,
      );
      expect(item.body, contains('처리기관: $_current'));
      expect(item.body, isNot(contains('경비교통과')));
      expect(item.extraData?['처리기관'], _raw['1814605'], reason: '원문 payload 보존');
    });
  });

  test('Report.fromJson uses server current name when registry is not loaded', () {
    AgencyRegistry.testInject(null);
    final withCurrent = Report.fromJson({
      '처리기관': _raw['1814605'],
      '처리기관코드': '1814605',
      'agency_name_current': _current,
    });
    expect(withCurrent.agency, _current);
    expect(withCurrent.agencyCode, '1814605');
    final legacy = Report.fromJson({'처리기관': _raw['1814605']});
    expect(legacy.agency, _raw['1814605']);
  });
}
