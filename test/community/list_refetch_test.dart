// 목록 상태 재조회·rebuild 선정 테스트 (vectors/list_refetch.json 규칙 +
// SyncEngine 연결부). 네트워크 없음.
//
// A07: override 종결여부가 선정에 섞이지 않는다 — 호출자가 사이트 원본을 넘기므로
// override_closed 벡터는 사이트 closed=N 으로 refetch=true 다.
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/list_refetch.dart';
import 'package:safetyreport/services/standalone_parser.dart';
import 'package:safetyreport/services/sync_engine.dart';

void main() {
  group('list label', () {
    test('C_NOW 코드 → 비교 라벨', () {
      expect(
          SyncEngine.listLabelForTest({'C_NOW': 0}), equals('진행'));
      expect(
          SyncEngine.listLabelForTest({'C_NOW': 10}), equals('답변완료'));
      expect(
          SyncEngine.listLabelForTest({'C_NOW': '11.0'}), equals('일부수용'));
      expect(SyncEngine.listLabelForTest({'C_NOW': 20}), equals('취하'));
      expect(SyncEngine.listLabelForTest({'C_NOW': 30}), equals('이송'));
    });

    test('상세 C_NOW 라벨과 같은 체계 (report.result 비교 가능)', () {
      // titleFieldsFromListItem 과 parseJsonToReport 의 C_NOW 매핑이 같다.
      expect(titleFieldsFromListItem({'C_NOW': 11})['상태'], equals('일부수용'));
    });
  });

  group('selection rule integration', () {
    bool select({
      required String? snapClosed,
      required String listLabel,
      required String? detailLabel,
      bool permanent = false,
      String? failedLabel,
      bool retry = false,
    }) =>
        shouldRefetchListItem(
          inPersonalDetail: true,
          listLabel: listLabel,
          detailStatusLabel: detailLabel,
          closed: snapClosed,
          supplementOpen: 'N',
          rebuildFailedPermanent: permanent,
          failedListLabel: failedLabel,
          inCaptureRetry: retry,
        );

    test('A07: override 는 무시 — 사이트 closed 기준', () {
      // 사이트 closed=Y + 라벨 동일 → 재조회 안 함 (사용자가 종결여부를
      // 고쳐도 사이트 기준으로 계속된다).
      expect(
          select(
              snapClosed: 'Y',
              listLabel: '답변완료',
              detailLabel: '답변완료'),
          isFalse);
      // 사이트 closed 가 null 이면 미종결 취급 → 재조회.
      expect(
          select(
              snapClosed: null, listLabel: '답변완료', detailLabel: '답변완료'),
          isTrue);
    });

    test('A09: 목록 라벨 변경이면 detail_status 와 비교해 재조회', () {
      expect(
          select(
              snapClosed: 'Y', listLabel: '취하', detailLabel: '답변완료'),
          isTrue);
      expect(
          select(
              snapClosed: 'Y', listLabel: '답변완료', detailLabel: '답변완료'),
          isFalse);
    });
  });

  group('rebuild selection', () {
    test('fetched 는 건너뛰고 pending·retryable 만 (재개)', () {
      final items = [
        {'C_NO': 'a'},
        {'C_NO': 'b'},
        {'C_NO': 'c'},
        {'C_NO': 'd'},
      ];
      final states = {
        'a': {'state': 'fetched', 'last_list_label': ''},
        'b': {'state': 'pending', 'last_list_label': ''},
        'c': {'state': 'failed_retryable', 'last_list_label': ''},
        'd': {'state': 'failed_permanent', 'last_list_label': '답변완료'},
      };
      final todo = SyncEngine.filterRebuildTodo(items, states);
      expect(todo.map((i) => i['C_NO']).toSet(), equals({'b', 'c'}));
    });

    test('부재 행 삭제 0 — orphan 수만 센다', () {
      expect(
          SyncEngine.countRebuildOrphans({'a', 'b', 'c'}, {'b', 'c', 'd'}),
          equals(1));
      expect(SyncEngine.countRebuildOrphans({'a'}, {'a'}), equals(0));
    });
  });
}
