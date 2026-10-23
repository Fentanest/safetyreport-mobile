// SR_REAL_MAP_DB points to a user-provided example database. Only read-only,
// immutable SQLite queries are used; no report values are embedded or logged.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/report_map.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/report_map_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

class _TransparentTiles extends TileProvider {
  static final _bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_bytes);
}

class _RealMapData {
  _RealMapData(this.path);
  final String path;
  final requests = <List<double>?>[];
  ReportMapPayload? lastPayload;
  LatLng? anchor;

  Future<ReportMapPayload> load({
    List<double>? bounds,
    required double zoom,
    String? year,
    required String category,
    required String pinBasis,
  }) async {
    requests.add(bounds == null ? null : List.of(bounds));
    final db = sqlite.sqlite3.open(
      Uri.file(
        path,
      ).replace(queryParameters: {'mode': 'ro', 'immutable': '1'}).toString(),
      mode: sqlite.OpenMode.readOnly,
      uri: true,
    );
    try {
      final where = <String>['1=1'];
      final args = <Object?>[];
      if (category != 'all') {
        where.add('category=?');
        args.add(category);
      }
      if (year != null) {
        where.add('답변일 LIKE ?');
        args.add('$year%');
      }
      final population = where.join(' AND ');
      const coordinates =
          '위도 IS NOT NULL AND 경도 IS NOT NULL '
          'AND 위도 BETWEEN -90 AND 90 AND 경도 BETWEEN -180 AND 180';
      final meta = db
          .select(
            'SELECT COUNT(*) AS total,COUNT(CASE WHEN $coordinates THEN 1 END) AS geo, '
            "COUNT(DISTINCT NULLIF(처리기관,'')) AS agencies FROM reports_effective WHERE $population",
            args,
          )
          .single;
      final groups =
          db
                  .select(
                    'SELECT COUNT(*) AS n FROM (SELECT 위도,경도,위반장소 FROM reports_effective WHERE $population AND $coordinates GROUP BY 위도,경도,위반장소)',
                    args,
                  )
                  .single['n']
              as int;
      final years = db
          .select(
            "SELECT DISTINCT substr(답변일,1,4) AS year FROM reports_effective ORDER BY year DESC",
          )
          .map((r) => r['year'])
          .whereType<String>()
          .where((s) => RegExp(r'^\d{4}$').hasMatch(s))
          .toList();
      if (anchor == null) {
        final row = db
            .select(
              'SELECT 위도 AS lat,경도 AS lng,COUNT(*) AS n FROM reports_effective WHERE $coordinates GROUP BY 위도,경도 ORDER BY n DESC LIMIT 1',
            )
            .single;
        anchor = LatLng(
          (row['lat'] as num).toDouble(),
          (row['lng'] as num).toDouble(),
        );
      }
      where.add(coordinates);
      if (bounds != null) {
        where.add('위도>=? AND 경도>=? AND 위도<? AND 경도<?');
        args.addAll(bounds);
      }
      final rows = db.select(
        'SELECT 위도 AS lat,경도 AS lng,위반장소 AS address,행정구역 AS region,처리상태 AS status, '
        '범칙금_과태료 AS fine,처리기관 AS agency,category,COUNT(*) AS n '
        'FROM reports_effective WHERE ${where.join(' AND ')} '
        'GROUP BY 위도,경도,위반장소,행정구역,처리상태,범칙금_과태료,처리기관,category',
        args,
      );
      final points = [
        for (final row in rows)
          ReportMapPoint(
            lat: (row['lat'] as num).toDouble(),
            lng: (row['lng'] as num).toDouble(),
            address: row['address'] as String? ?? '',
            region: row['region'] as String? ?? '',
            total: row['n'] as int,
            statusBreakdown: [
              ReportMapBreakdownItem(
                label: row['status'] as String? ?? '',
                count: row['n'] as int,
                pct: 100,
              ),
            ],
            dispositionBreakdown: (row['fine'] as String? ?? '').contains('과태료')
                ? [
                    ReportMapBreakdownItem(
                      label: '과태료',
                      count: row['n'] as int,
                      pct: 100,
                    ),
                  ]
                : const [],
            agencyBreakdown: [
              ReportMapAgencyItem(
                name: row['agency'] as String? ?? '',
                count: row['n'] as int,
                pct: 100,
              ),
            ],
            categoryBreakdown: [
              ReportMapBreakdownItem(
                label: row['category'] as String? ?? '',
                count: row['n'] as int,
                pct: 100,
              ),
            ],
          ),
      ];
      return lastPayload = ReportMapPayload(
        points: points,
        meta: ReportMapMeta(
          availableYears: years,
          currentYear: year ?? 'all',
          selectedCategory: category,
          dedupeMode: 'raw',
          pinBasis: pinBasis,
          totalReports: meta['total'] as int,
          geocodedReports: meta['geo'] as int,
          missingReports: (meta['total'] as int) - (meta['geo'] as int),
          addressGroups: groups,
          agencyCount: meta['agencies'] as int,
        ),
      );
    } finally {
      db.close();
    }
  }
}

List<double> _bounds(MapCamera camera) {
  final b = camera.visibleBounds;
  return [b.south, b.west, b.north, b.east];
}

bool _sameBounds(List<double>? a, List<double> b) =>
    a != null &&
    a.length == b.length &&
    Iterable.generate(b.length).every((i) => (a[i] - b[i]).abs() < 1e-9);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<_RealMapData> _pump(WidgetTester tester, String path) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final provider = ReportProvider();
  addTearDown(provider.dispose);
  final source = _RealMapData(path);
  await tester.pumpWidget(
    ChangeNotifierProvider<ReportProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: ReportMapScreen(
          payloadLoader: source.load,
          tileProvider: _TransparentTiles(),
        ),
      ),
    ),
  );
  await _settle(tester);
  return source;
}

void main() {
  final path = Platform.environment['SR_REAL_MAP_DB'];
  final skip = path == null || !File(path).existsSync();
  testWidgets('실제 DB: 회전 후 넓어진 영역의 핀을 다시 읽고 응답 재빌드로 반복 조회하지 않는다', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final oldError = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      final source = await _pump(tester, path!);
      expect(source.requests.length, 1, reason: '첫 레이아웃은 전체 조회를 반복하지 않는다');
      final map = find.byType(FlutterMap);
      await tester.ensureVisible(find.byTooltip('현재 위치'));
      await _settle(tester);
      final controller = tester.widget<FlutterMap>(map).mapController!;
      controller.move(source.anchor!, 15);
      await _settle(tester);
      await tester.drag(map, const Offset(50, 0));
      await _settle(tester);
      expect(source.requests.length, 2);
      final oldPoints = {
        for (final p in source.lastPayload!.points) (p.lat, p.lng),
      };
      final oldBounds = source.requests.last!;
      tester.view.physicalSize = const Size(800, 400);
      await _settle(tester);
      expect(source.requests.length, 3, reason: '회전된 실제 지도 크기로 한 번 다시 조회한다');
      expect(
        _sameBounds(source.requests.last, _bounds(controller.camera)),
        isTrue,
        reason: '조회 범위가 화면의 현재 영역과 같아야 한다',
      );
      expect(_sameBounds(source.requests.last, oldBounds), isFalse);
      final newPoints = {
        for (final p in source.lastPayload!.points) (p.lat, p.lng),
      };
      expect(
        newPoints.difference(oldPoints).isNotEmpty,
        isTrue,
        reason: '새로 보이는 영역의 실제 DB 좌표도 결과에 들어온다',
      );
      final count = source.requests.length;
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(source.requests.length, count, reason: '응답/마커 재빌드로 조회가 반복되지 않는다');
      // 여러 크기 변경이 연달아 와도 마지막 범위만 읽는다.
      tester.view.physicalSize = const Size(720, 400);
      await tester.pump(const Duration(milliseconds: 80));
      tester.view.physicalSize = const Size(740, 400);
      await tester.pump(const Duration(milliseconds: 80));
      tester.view.physicalSize = const Size(760, 400);
      await _settle(tester);
      expect(source.requests.length, count + 1);
      expect(
        _sameBounds(source.requests.last, _bounds(controller.camera)),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(errors.length, 0, reason: '원문 노출 없이 렌더 오류 건수만 확인한다');
    } finally {
      FlutterError.onError = oldError;
    }
  }, skip: skip);

  testWidgets('실제 DB: 회전 debounce 중 화면을 닫으면 재조회하지 않는다', (tester) async {
    final source = await _pump(tester, path!);
    final before = source.requests.length;
    tester.view.physicalSize = const Size(800, 400);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpWidget(const SizedBox.shrink());
    // 실제 권한 브리지의 5초 timeout도 마무리한다(플랫폼 응답을 위조하지 않는다).
    await tester.pump(const Duration(seconds: 6));
    expect(source.requests.length, before);
  }, skip: skip);
}
