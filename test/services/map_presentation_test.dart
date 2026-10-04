import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report_map.dart';
import 'package:safetyreport/services/map_presentation.dart';

void main() {
  test(
    '500000 reports retain all counts in bounded cells; viewport only changes display',
    () {
      final points = List.generate(
        500000,
        (i) => ReportMapPoint(
          lat: 33 + (i % 6000) / 1000,
          lng: 125 + (i % 5000) / 1000,
          address: 'fixture',
          region: '',
          total: 1,
          statusBreakdown: const [
            ReportMapBreakdownItem(label: '수용', count: 1, pct: 100),
          ],
          dispositionBreakdown: const [
            ReportMapBreakdownItem(label: '과태료', count: 1, pct: 100),
          ],
          agencyBreakdown: const [
            ReportMapAgencyItem(name: '합성 기관', count: 1, pct: 100),
          ],
          categoryBreakdown: const [],
        ),
      );
      final cells = visibleMapCells(points, null);
      expect(cells.length, lessThanOrEqualTo(1024));
      expect(cells.fold<int>(0, (n, p) => n + p.total), 500000);
      expect(
        cells.fold<int>(0, (n, p) => n + p.statusBreakdown.single.count),
        500000,
      );
      final box = [35.0, 126.0, 37.0, 128.0];
      final visible = points
          .where(
            (p) =>
                p.lat >= box[0] &&
                p.lat < box[2] &&
                p.lng >= box[1] &&
                p.lng < box[3],
          )
          .length;
      expect(
        visibleMapCells(points, box).fold<int>(0, (n, p) => n + p.total),
        visible,
      );
    },
  );

  test('SQ-U03 표시용 셀 묶음은 일반 문구 대신 대표 시·군·구를 지역 이름으로 갖는다(건수는 그대로)', () {
    ReportMapPoint p(double lat, double lng, String address, int total) =>
        ReportMapPoint(
          lat: lat,
          lng: lng,
          address: address,
          region: '',
          total: total,
          statusBreakdown: const [],
          dispositionBreakdown: const [],
          agencyBreakdown: const [],
          categoryBreakdown: const [],
        );
    final cells = visibleMapCells([
      p(37.5, 127.03, '서울특별시 강남구 테헤란로 1', 5),
      p(37.56, 126.9, '서울특별시 마포구 월드컵로 2', 2),
      p(33.5, 126.53, '제주특별자치도 제주시 문연로 6', 3),
    ], null);
    expect(cells, hasLength(2));
    final group = cells.singleWhere((c) => c.isCluster);
    expect(group.total, 7);
    expect(group.region, '강남구 외');
    final single = cells.singleWhere((c) => !c.isCluster);
    expect(single.region, '');
    expect(single.address, '제주특별자치도 제주시 문연로 6');
  });
}
