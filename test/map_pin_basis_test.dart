// 신고 지도 핀 기준(pin_basis) — contracts/map-pin-basis-vectors.json(서버와 바이트 동일).
// Standalone 계산(LocalDbService)이 벡터와 같은 effective 좌표·geocoded/missing 건수·
// 점 집합(lat,lng,total)·좌표 없는 그룹을 내는지 본다. 표시용 계산이며 DB 의 위도·경도는
// 바꾸지 않는다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report_map.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> _vectors() => jsonDecode(
  File('contracts/map-pin-basis-vectors.json').readAsStringSync(),
) as Map<String, dynamic>;

List<Map<String, Object?>> _vectorRows(Map<String, dynamic> vectors) => [
  for (final row in (vectors['rows'] as List))
    Map<String, Object?>.from(row as Map),
];

Map<String, List<double>?> _expectedEffective(Map<String, dynamic> mode) {
  final out = <String, List<double>?>{};
  (mode['effective'] as Map).forEach((key, value) {
    if (value == null) {
      out[key as String] = null;
    } else {
      out[key as String] = [
        for (final v in (value as List)) (v as num).toDouble(),
      ];
    }
  });
  return out;
}

Future<void> _resetDb() async {
  await LocalDbService.closeDb();
  final dbPath = await LocalDbService.getDbPath();
  await deleteDatabase(dbPath);
  for (final ext in ['-wal', '-shm']) {
    final sidecar = File('$dbPath$ext');
    if (sidecar.existsSync()) {
      await sidecar.delete();
    }
  }
}

Future<void> _seedVectors(Map<String, dynamic> vectors) async {
  final db = await LocalDbService.db;
  for (final row in (vectors['rows'] as List)) {
    final r = row as Map;
    await db.insert('reports', {
      'ID': r['ID'],
      '신고번호': "PIN-${r['ID']}",
      '신고일': '2026-01-01',
      '답변일': '2026-01-02',
      '위반장소': r['위반장소'],
      '주소정규화': r['주소정규화'],
      '위도': r['위도'],
      '경도': r['경도'],
      'category': 'traffic',
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDbDir;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // flutter test 는 파일별로 병렬 실행된다. DB 를 쓰는 테스트 파일마다 전용 경로를 쓴다.
    await databaseFactory.setDatabasesPath(
      (tempDbDir = Directory.systemTemp.createTempSync('sr_pin_basis_test_'))
          .path,
    );
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    if (tempDbDir.existsSync()) tempDbDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _resetDb();
  });
  tearDown(() async {
    await _resetDb();
  });

  group('map pin basis vectors', () {
    test('pure: effective 좌표가 양 모드 벡터와 같다', () {
      final vectors = _vectors();
      final rows = _vectorRows(vectors);
      final expected = vectors['expected'] as Map<String, dynamic>;
      for (final basis in ['coords', 'address']) {
        final resolved = LocalDbService.resolveMapPinBasis(rows, basis);
        final want = _expectedEffective(
          expected[basis] as Map<String, dynamic>,
        );
        expect(resolved.effective.keys.toSet(), want.keys.toSet());
        for (final id in want.keys) {
          final got = resolved.effective[id];
          final w = want[id];
          if (w == null) {
            expect(got, isNull, reason: '$basis $id');
          } else {
            expect(got, isNotNull, reason: '$basis $id');
            expect(got![0], closeTo(w[0], 1e-9), reason: '$basis $id lat');
            expect(got[1], closeTo(w[1], 1e-9), reason: '$basis $id lng');
          }
        }
      }
    });

    test('standalone stats: meta 건수·pin_basis (양 모드)', () async {
      final vectors = _vectors();
      await _seedVectors(vectors);
      final expected = vectors['expected'] as Map<String, dynamic>;
      for (final basis in ['coords', 'address']) {
        final raw = await LocalDbService.computeReportMapStats(
          pinBasis: basis,
        );
        final payload = ReportMapPayload.fromJson(raw);
        final want = expected[basis] as Map<String, dynamic>;
        expect(raw['meta']['pin_basis'], basis);
        expect(payload.meta.pinBasis, basis);
        expect(payload.meta.totalReports, 11);
        expect(payload.meta.geocodedReports, want['geocoded_reports']);
        expect(payload.meta.missingReports, want['missing_reports']);
      }
      // 기본값(인자 생략)은 coords 와 같다. 모르는 값도 coords 로 정규화한다.
      final def = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(),
      );
      final co = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(pinBasis: 'coords'),
      );
      final bogus = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(pinBasis: 'bogus'),
      );
      expect(def.meta.pinBasis, 'coords');
      expect(def.meta.geocodedReports, co.meta.geocodedReports);
      expect(def.meta.missingReports, co.meta.missingReports);
      expect(bogus.meta.geocodedReports, co.meta.geocodedReports);
      expect(bogus.meta.missingReports, co.meta.missingReports);
      // 표시용 계산이며 저장 좌표는 그대로다(A3 은 자기 좌표 유지).
      final db = await LocalDbService.db;
      final a3 = (await db.query(
        'reports',
        where: 'ID = ?',
        whereArgs: ['A3'],
      )).single;
      expect(a3['위도'], 37.567);
      expect(a3['경도'], 126.979);
    });

    test('standalone stats: 점 집합(lat,lng,total)이 벡터와 같다', () async {
      final vectors = _vectors();
      await _seedVectors(vectors);
      final expected = vectors['expected'] as Map<String, dynamic>;
      for (final basis in ['coords', 'address']) {
        final wantPoints = [
          for (final p in ((expected[basis] as Map<String, dynamic>)['points']
              as List))
            (
              (p['lat'] as num).toDouble(),
              (p['lng'] as num).toDouble(),
              p['total'] as int,
            ),
        ];
        // 셀 집계는 화면 범위로 묶으므로 기대 점마다 그 점만 담는 좁은 범위로
        // 조회해 (lat,lng,total)을 확인한다. bounds 거르기도 effective 기준이다.
        final seen = <String>{};
        for (final want in wantPoints) {
          const eps = 0.0002;
          final raw = await LocalDbService.computeReportMapStats(
            pinBasis: basis,
            bounds: [
              want.$1 - eps,
              want.$2 - eps,
              want.$1 + eps,
              want.$2 + eps,
            ],
          );
          final payload = ReportMapPayload.fromJson(raw);
          expect(
            payload.points,
            hasLength(1),
            reason: '$basis ${want.$1},${want.$2}',
          );
          final point = payload.points.single;
          expect(point.lat, closeTo(want.$1, 1e-9));
          expect(point.lng, closeTo(want.$2, 1e-9));
          expect(point.total, want.$3);
          seen.add('${point.lat},${point.lng},${point.total}');
        }
        expect(seen, hasLength(wantPoints.length));
      }
    });

    test('standalone missing: 그룹 수·건수·구성원이 벡터와 같다', () async {
      final vectors = _vectors();
      await _seedVectors(vectors);
      final expected = vectors['expected'] as Map<String, dynamic>;

      var raw = await LocalDbService.computeReportMapMissingGroups();
      var payload = ReportMapMissingPayload.fromJson(raw);
      var wantMissing =
          (expected['coords'] as Map<String, dynamic>)['missing_groups']
              as Map;
      expect(raw['meta']['pin_basis'], 'coords');
      expect(payload.groupCount, wantMissing['group_count']);
      expect(payload.reportCount, wantMissing['report_count']);
      expect(
        {for (final g in payload.groups) for (final r in g.reports) r.id},
        {'A4', 'C1', 'C2', 'E2'},
      );

      raw = await LocalDbService.computeReportMapMissingGroups(
        pinBasis: 'address',
      );
      payload = ReportMapMissingPayload.fromJson(raw);
      wantMissing =
          (expected['address'] as Map<String, dynamic>)['missing_groups']
              as Map;
      expect(raw['meta']['pin_basis'], 'address');
      expect(payload.groupCount, wantMissing['group_count']);
      expect(payload.reportCount, wantMissing['report_count']);
      expect(
        {for (final g in payload.groups) for (final r in g.reports) r.id},
        {'C1', 'C2'},
      );
    });
  });
}
