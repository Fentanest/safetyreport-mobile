import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report_map.dart';
import 'package:safetyreport/services/map_presentation.dart';
import 'package:safetyreport/theme/sr_colors.dart';
import 'package:safetyreport/widgets/report_map_overlays.dart';

import '../support/ui_harness.dart';

ReportMapPoint _p({
  String address = '',
  String region = '',
  bool cluster = false,
  int total = 1,
  double lat = 37.5,
  double lng = 127.0,
}) => ReportMapPoint(
  isCluster: cluster,
  lat: lat,
  lng: lng,
  address: address,
  region: region,
  total: total,
  statusBreakdown: const [],
  dispositionBreakdown: const [],
  agencyBreakdown: const [],
  categoryBreakdown: const [],
);

Color _textColor(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text)).text.style!.color!;

void main() {
  group('SQ-U03 마커 라벨 문구', () {
    test('주소·행정구역에서 시·군·구 이름을 뽑는다', () {
      expect(mapRegionShortLabel('서울특별시 강남구 테헤란로 1'), '강남구');
      expect(mapRegionShortLabel('서울 마포구 월드컵로 2'), '마포구');
      expect(mapRegionShortLabel('경기도 수원시 영통구 광교로 3'), '수원시 영통구');
      expect(mapRegionShortLabel('경기도 고양시 일산동구 중앙로 4'), '일산동구');
      expect(mapRegionShortLabel('충청남도 홍성군 홍성읍 5'), '홍성군');
      expect(mapRegionShortLabel('세종특별자치시 한누리대로 6'), '세종시');
      expect(mapRegionShortLabel('강남구 외'), '강남구 외');
      expect(mapRegionShortLabel('테헤란로 1'), '');
      expect(mapRegionShortLabel(''), '');
    });

    test('일반 집계 문구 대신 지역 이름이나 건수를 보인다', () {
      // 서버 클러스터(report_stats_service: region '영역 집계', address '이 영역의 신고').
      expect(
        mapMarkerRegionLabel(
          _p(cluster: true, region: '영역 집계', address: '이 영역의 신고', total: 12),
        ),
        '12건 묶음',
      );
      // 로컬 클러스터(local_statistics).
      expect(
        mapMarkerRegionLabel(
          _p(cluster: true, address: '지도 구역 집계 · 확대하여 주소 확인', total: 4),
        ),
        '4건 묶음',
      );
      expect(mapMarkerRegionLabel(_p(address: '부산광역시 해운대구 해운대해변로 2')), '해운대구');
      expect(
        mapMarkerRegionLabel(
          _p(region: '서울특별시 종로구', address: '서울특별시 중구 세종대로 1'),
        ),
        '종로구',
      );
      // 시·군·구를 못 찾으면 원문을 그대로 쓴다(말줄임은 라벨이 처리).
      expect(mapMarkerRegionLabel(_p(address: '테헤란로 1')), '테헤란로 1');
      expect(mapMarkerRegionLabel(_p(total: 2)), '2건');
    });

    test('여러 지점의 대표 지역은 신고가 가장 많은 곳, 둘 이상이면 "외"', () {
      expect(
        dominantMapRegionLabel([
          _p(address: '서울특별시 마포구 a', total: 2),
          _p(address: '서울특별시 강남구 b', total: 5),
        ]),
        '강남구 외',
      );
      expect(
        dominantMapRegionLabel([
          _p(address: '서울특별시 강남구 a', total: 1),
          _p(address: '서울특별시 강남구 b', total: 1),
        ]),
        '강남구',
      );
      expect(
        dominantMapRegionLabel([_p(cluster: true, region: '영역 집계', total: 3)]),
        '',
      );
    });
  });

  group('SQ-U24 과태료율 구간', () {
    test('경계값과 색은 예전 마커 색 규칙과 같다', () {
      expect(MapFineRateBand.of(100), MapFineRateBand.high);
      expect(MapFineRateBand.of(60), MapFineRateBand.high);
      expect(MapFineRateBand.of(59.9), MapFineRateBand.mid);
      expect(MapFineRateBand.of(50), MapFineRateBand.mid);
      expect(MapFineRateBand.of(49.9), MapFineRateBand.low);
      expect(MapFineRateBand.of(0), MapFineRateBand.low);
      expect(MapFineRateBand.high.color, const Color(0xFF2E7D32));
      expect(MapFineRateBand.mid.color, const Color(0xFFF57C00));
      expect(MapFineRateBand.low.color, const Color(0xFFC62828));
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('SQ-U03 마커 라벨 대비·크기 (${brightness.name})', (tester) async {
      final errors = await pumpThemed(
        tester,
        const Center(child: MapMarkerRegionPill(label: '강남구')),
        brightness: brightness,
      );
      expect(errors, isEmpty, reason: describeErrors(errors));
      final paragraph = tester.renderObject<RenderParagraph>(find.text('강남구'));
      expect(paragraph.text.style!.fontSize, greaterThanOrEqualTo(11));
      expect(
        contrastRatio(
          _textColor(tester, '강남구'),
          MapMarkerRegionPill.background,
        ),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('SQ-U24 범례 접기·펼치기와 글자 대비 (${brightness.name})', (tester) async {
      final errors = await pumpThemed(
        tester,
        const Align(alignment: Alignment.topLeft, child: MapFineRateLegend()),
        brightness: brightness,
      );
      expect(errors, isEmpty, reason: describeErrors(errors));
      final sr = brightness == Brightness.dark ? SrColors.dark : SrColors.light;
      final legendBackground = sr.surface.withValues(alpha: 0.96);
      expect(find.text('과태료율'), findsOneWidget);
      expect(find.text('과태료율 60% 이상'), findsNothing);

      await tester.tap(find.text('과태료율'));
      await tester.pump();
      for (final band in MapFineRateBand.values) {
        expect(find.text(band.label), findsOneWidget);
        expect(
          contrastRatio(_textColor(tester, band.label), legendBackground),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(find.text('여러 지점 묶음'), findsOneWidget);
      // 접기 버튼 터치 영역.
      expect(
        tester.getSize(find.byType(InkWell).first).height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('SQ-U10 출처 표기 대비 (${brightness.name})', (tester) async {
      final errors = await pumpThemed(
        tester,
        const Align(
          alignment: Alignment.bottomLeft,
          child: MapOsmAttribution(),
        ),
        brightness: brightness,
      );
      expect(errors, isEmpty, reason: describeErrors(errors));
      final sr = brightness == Brightness.dark ? SrColors.dark : SrColors.light;
      expect(
        contrastRatio(
          _textColor(tester, MapOsmAttribution.text),
          sr.surface.withValues(alpha: 0.9),
        ),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  testWidgets('SQ-U03 큰 글꼴(2.0배)에서도 라벨이 넘치지 않는다', (tester) async {
    final errors = await pumpThemed(
      tester,
      const Center(
        child: SizedBox(
          width: 100,
          height: 30,
          child: MapMarkerRegionPill(label: '수원시 영통구'),
        ),
      ),
      brightness: Brightness.light,
      textScale: 2.0,
    );
    expect(errors, isEmpty, reason: describeErrors(errors));
  });
}
