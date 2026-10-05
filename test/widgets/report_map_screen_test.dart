import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/models/report_map.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_map_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/theme/sr_colors.dart';
import 'package:safetyreport/widgets/report_map_overlays.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 지도 화면(WP5: SQ-U03·U10·U11·P05·U24) 회귀 테스트. 네트워크·위치 플러그인 없이 주입한 가짜로 돈다.

class _FakeLocation extends ReportMapLocationGateway {
  _FakeLocation({
    this.granted = false,
    this.result = LocationPermission.denied,
  });

  bool granted;
  LocationPermission result;
  int checks = 0;
  int requests = 0;
  int positions = 0;

  @override
  Future<bool> isPermissionGranted() async {
    checks++;
    return granted;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    if (result == LocationPermission.whileInUse ||
        result == LocationPermission.always) {
      granted = true;
    }
    return result;
  }

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<Position> getCurrentPosition() async {
    positions++;
    return Position(
      latitude: 37.5,
      longitude: 127.03,
      timestamp: DateTime(2026, 10, 4),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }

  @override
  Future<Position?> getLastKnownPosition() async => null;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  Future<bool> openAppSettings() async => true;
}

class _ScopeProvider extends ReportProvider {
  int epoch = 0;

  @override
  int get datasetEpoch => epoch;

  void bumpEpoch() {
    epoch++;
    notifyListeners();
  }

  void notifyUnrelated() => notifyListeners();

  // 드릴다운 목록(ReportListScreen)이 열려도 네트워크에 가지 않는다.
  @override
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async => (reports: <Report>[], total: 0);

  @override
  Future<void> fetchDuplicateReports() async {}
}

final _transparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _BlankTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_transparentPng);
}

ReportMapPoint _point(
  double lat,
  double lng,
  String address, {
  required int total,
  required int fines,
}) => ReportMapPoint(
  lat: lat,
  lng: lng,
  address: address,
  region: '',
  total: total,
  statusBreakdown: const [],
  dispositionBreakdown: [
    ReportMapBreakdownItem(
      label: '과태료',
      count: fines,
      pct: fines * 100 / total,
    ),
  ],
  agencyBreakdown: const [],
  categoryBreakdown: const [],
);

/// 첫 조회(화면 범위 없음)의 표시용 셀 집계에서 서울 두 지점은 한 셀로 묶이고(과태료 5/7 → 60% 이상),
/// 제주 한 지점은 따로 남는다(과태료 1/3 → 50% 미만).
ReportMapPayload _payload() => ReportMapPayload(
  points: [
    _point(37.5, 127.03, '서울특별시 강남구 테헤란로 1', total: 5, fines: 4),
    _point(37.56, 126.9, '서울특별시 마포구 월드컵로 2', total: 2, fines: 1),
    _point(33.5, 126.53, '제주특별자치도 제주시 문연로 6', total: 3, fines: 1),
  ],
  meta: const ReportMapMeta(
    availableYears: ['2026'],
    currentYear: 'all',
    selectedCategory: 'all',
    dedupeMode: 'raw',
    totalReports: 10,
    geocodedReports: 10,
    missingReports: 0,
    addressGroups: 3,
    agencyCount: 0,
  ),
);

class _Harness {
  _Harness({_FakeLocation? location}) : location = location ?? _FakeLocation();

  final _FakeLocation location;
  final provider = _ScopeProvider();
  final brightness = ValueNotifier<Brightness>(Brightness.light);
  int loads = 0;
  String lastPinBasis = 'coords';

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(provider.dispose);
    addTearDown(brightness.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: ValueListenableBuilder<Brightness>(
          valueListenable: brightness,
          builder: (context, value, _) => MaterialApp(
            theme: AppTheme.build(value),
            home: ReportMapScreen(
              locationGateway: location,
              tileProvider: _BlankTileProvider(),
              payloadLoader:
                  ({
                    bounds,
                    required zoom,
                    year,
                    required category,
                    required pinBasis,
                  }) async {
                    loads++;
                    lastPinBasis = pinBasis;
                    return _payload();
                  },
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

List<Marker> _clusterMarkers(WidgetTester tester) => tester
    .widget<MarkerClusterLayerWidget>(find.byType(MarkerClusterLayerWidget))
    .options
    .markers;

void main() {
  group('SQ-U11 위치 권한은 버튼을 누르고 설명을 본 뒤에만 요청', () {
    testWidgets('화면 진입만으로는 권한을 요청하지 않는다', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      expect(h.location.requests, 0);
      expect(find.byType(AlertDialog), findsNothing);
      // 권한이 없을 때 진입만으로 "위치 꺼짐" 오류 아이콘을 띄우지 않는다.
      expect(find.byIcon(Icons.my_location), findsOneWidget);
    });

    testWidgets('버튼 → 설명 창 → 취소면 요청하지 않고, 허용이면 요청한다', (tester) async {
      final h = _Harness(
        location: _FakeLocation(result: LocationPermission.whileInUse),
      );
      await h.pump(tester);

      await tester.tap(find.byTooltip('현재 위치'));
      await h.settle(tester);
      expect(find.text('지도에서 내 위치로 이동하려면 위치 권한이 필요합니다.'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await h.settle(tester);
      expect(h.location.requests, 0);
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.byTooltip('현재 위치'));
      await h.settle(tester);
      await tester.tap(find.text('허용'));
      await h.settle(tester);
      expect(h.location.requests, 1);
      expect(h.location.positions, 1);
    });

    testWidgets('영구 거부면 설정으로 가는 SnackBar 를 그대로 보인다', (tester) async {
      final h = _Harness(
        location: _FakeLocation(result: LocationPermission.deniedForever),
      );
      await h.pump(tester);
      await tester.tap(find.byTooltip('현재 위치'));
      await h.settle(tester);
      await tester.tap(find.text('허용'));
      await h.settle(tester);
      expect(h.location.requests, 1);
      expect(find.text('위치 권한이 차단되어 있습니다.'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '설정'), findsOneWidget);
    });

    testWidgets('이미 허용돼 있으면 설명 창 없이 현재 위치를 쓴다', (tester) async {
      final h = _Harness(location: _FakeLocation(granted: true));
      await h.pump(tester);
      expect(h.location.requests, 0);
      expect(h.location.positions, 1);
      await tester.tap(find.byTooltip('현재 위치'));
      await h.settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.location.requests, 0);
      expect(h.location.positions, 2);
    });
  });

  group('SQ-P05 마커 캐시와 Provider 구독 축소', () {
    testWidgets('조회 결과가 같으면 다시 그려도 같은 마커 리스트 인스턴스를 쓴다', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      final before = _clusterMarkers(tester);
      expect(before, hasLength(2));

      // 테마가 바뀌어 화면이 다시 build 되어도 조회 결과는 같다.
      h.brightness.value = Brightness.dark;
      await h.settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(identical(_clusterMarkers(tester), before), isTrue);
      expect(h.loads, 1);
    });

    testWidgets('관련 없는 Provider 알림은 재조회하지 않고, 데이터 범위가 바뀌면 다시 조회한다', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester);
      final before = _clusterMarkers(tester);

      h.provider.notifyUnrelated();
      await h.settle(tester);
      expect(h.loads, 1);
      expect(identical(_clusterMarkers(tester), before), isTrue);

      h.provider.bumpEpoch();
      await h.settle(tester);
      expect(h.loads, 2);
      expect(identical(_clusterMarkers(tester), before), isFalse);
      expect(_clusterMarkers(tester), hasLength(2));
    });
  });

  group('SQ-P02 자료 변경 신호', () {
    testWidgets('통계 탭 진입 신호로는 다시 조회하지 않고, 실제 변경이면 한 번 다시 조회한다', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      expect(h.loads, 1);

      h.provider.bumpStatsRefresh();
      await h.settle(tester);
      expect(h.loads, 1);

      h.provider.markDataChanged();
      await h.settle(tester);
      expect(h.loads, 2);
    });

    testWidgets('다른 화면에 가려진 동안의 변경은 다시 보일 때 한 번만 조회한다', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      expect(h.loads, 1);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('위 화면')),
        ),
      );
      await tester.pumpAndSettle();
      h.provider.markDataChanged();
      h.provider.markDataChanged();
      await h.settle(tester);
      expect(h.loads, 1, reason: '가려진 지도는 조회하지 않는다');

      navigator.pop();
      await tester.pumpAndSettle();
      await h.settle(tester);
      expect(h.loads, 2);
    });
  });

  group('핀 기준 토글(위도·경도/주소)', () {
    testWidgets('전환하면 다시 조회하고 주소 모드 안내를 보인다', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      expect(h.loads, 1);
      expect(h.lastPinBasis, 'coords');
      expect(find.text('핀 기준'), findsOneWidget);
      expect(
        find.text(
          '같은 주소의 신고를 한 핀으로 묶고, 그 주소에서 가장 많이 신고된 공식 좌표에 표시합니다.',
        ),
        findsNothing,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, '주소'));
      await h.settle(tester);
      expect(h.loads, 2);
      expect(h.lastPinBasis, 'address');
      expect(
        find.text(
          '같은 주소의 신고를 한 핀으로 묶고, 그 주소에서 가장 많이 신고된 공식 좌표에 표시합니다.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, '위도·경도'));
      await h.settle(tester);
      expect(h.loads, 3);
      expect(h.lastPinBasis, 'coords');
      expect(
        find.text(
          '같은 주소의 신고를 한 핀으로 묶고, 그 주소에서 가장 많이 신고된 공식 좌표에 표시합니다.',
        ),
        findsNothing,
      );
    });
  });

  testWidgets('SQ-U10 지도에 OpenStreetMap 출처를 보인다', (tester) async {    final h = _Harness();
    await h.pump(tester);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(find.bySemanticsLabel('OpenStreetMap 저작권 안내 열기'), findsOneWidget);
  });

  testWidgets('SQ-U03 다크 테마에서도 마커 라벨은 시·군·구 이름을 읽을 수 있는 대비로 보인다', (
    tester,
  ) async {
    final h = _Harness();
    h.brightness.value = Brightness.dark;
    await h.pump(tester);
    for (final name in ['강남구 외', '제주시']) {
      final finder = find.text(name);
      expect(finder, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(finder);
      final style = paragraph.text.style!;
      expect(style.fontSize, greaterThanOrEqualTo(11));
      expect(
        contrastRatio(style.color!, MapMarkerRegionPill.background),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(find.textContaining('지도 구역 집계'), findsNothing);
  });

  testWidgets('SQ-U24 지도에 접이식 과태료율 범례가 있다', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = _Harness();
    await h.pump(tester);
    expect(find.byType(MapFineRateLegend), findsOneWidget);
    expect(find.text('과태료율 60% 이상'), findsNothing);
    await tester.tap(find.text('과태료율'));
    await h.settle(tester);
    expect(find.text('과태료율 60% 이상'), findsOneWidget);
    expect(find.text('과태료율 50~60%'), findsOneWidget);
    expect(find.text('과태료율 50% 미만'), findsOneWidget);
    // 마커는 색 말고도 스크린리더 문구로 구간을 알린다.
    expect(find.bySemanticsLabel('강남구 외, 7건, 과태료율 60% 이상'), findsOneWidget);
    expect(find.bySemanticsLabel('제주시, 3건, 과태료율 50% 미만'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('SQ-U02 지도 "리스트 보기" 드릴다운은 공용 필터를 바꾸지 않는다', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    expect(h.provider.filter, const ReportFilter());

    // 첫 클러스터 애니메이션이 끝나야 마커 탭을 받는다.
    await tester.pump(const Duration(seconds: 2));
    // 지도 제스처(두 번 탭 확대 등)와 경합하지 않도록 마커의 탭 처리기를 직접 부른다.
    final markerTap = tester
        .widgetList<GestureDetector>(
          find.ancestor(
            of: find.text('제주시'),
            matching: find.byType(GestureDetector),
          ),
        )
        .firstWhere((g) => g.onTap != null);
    markerTap.onTap!();
    await h.settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('리스트 보기'));
    await tester.tap(find.text('리스트 보기'));
    await h.settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('제주특별자치도 제주시 문연로 6 · 신고'), findsOneWidget);
    expect(find.text('위반장소: 제주특별자치도 제주시 문연로 6'), findsOneWidget);
    expect(h.provider.filter, const ReportFilter());
    expect(h.provider.hasFilter, isFalse);

    await tester.pageBack();
    await h.settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.provider.filter, const ReportFilter());
  });
}
