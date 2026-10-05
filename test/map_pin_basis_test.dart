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
    test('standalone: 신고별 effective 좌표가 양 모드 벡터와 같다', () async {
      final vectors = _vectors();
      await _seedVectors(vectors);
      final expected = vectors['expected'] as Map<String, dynamic>;
      for (final basis in ['coords', 'address']) {
        final want = _expectedEffective(
          expected[basis] as Map<String, dynamic>,
        );
        final rows = await LocalDbService.debugMapEffectiveRows(
          pinBasis: basis,
        );
        final got = {
          for (final r in rows)
            r['ID'] as String: r['lat'] == null
                ? null
                : [(r['lat'] as num).toDouble(), (r['lng'] as num).toDouble()],
        };
        expect(got.keys.toSet(), want.keys.toSet(), reason: basis);
        for (final id in want.keys) {
          expect(got[id], want[id], reason: '$basis $id');
        }
      }
    });

    test('주소키 strip 집합·경계 사례가 서버와 같다(Dart·SQLite 둘 다)', () async {
      final vectors = _vectors();
      expect(
        LocalDbService.mapStripCodePoints,
        (vectors['strip_code_points'] as List).cast<int>(),
      );
      final cases = (vectors['key_cases'] as List).cast<Map>();
      final db = await LocalDbService.db;
      for (var i = 0; i < cases.length; i++) {
        final c = cases[i];
        expect(
          LocalDbService.mapPinBasisKey(c['주소정규화'], c['위반장소']),
          c['key'],
          reason: 'dart $i',
        );
        await db.insert('reports', {
          'ID': 'K$i',
          '신고번호': 'KEY-$i',
          '답변일': '2026-01-02',
          '주소정규화': c['주소정규화'],
          '위반장소': c['위반장소'],
          '위도': 37.5,
          '경도': 127.0,
          'category': 'traffic',
        });
      }
      // SQLite 안의 키를 바이트(hex)로 비교한다. Dart UTF-8 디코더는 맨 앞 BOM 을 지우기 때문이다.
      String hex(String text) => utf8
          .encode(text)
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join();
      final rows = await LocalDbService.debugMapEffectiveRows();
      final keys = {for (final r in rows) r['ID']: r['addr_key_hex']};
      for (var i = 0; i < cases.length; i++) {
        expect(keys['K$i'], hex(cases[i]['key'] as String), reason: 'sqlite $i');
      }
    });

    test('핀 기준 값은 앞뒤 공백·대소문자를 무시한다(서버와 같음)', () {
      expect(LocalDbService.normalizeMapPinBasis(' ADDRESS '), 'address');
      expect(LocalDbService.normalizeMapPinBasis('Address'), 'address');
      expect(LocalDbService.normalizeMapPinBasis(null), 'coords');
      expect(LocalDbService.normalizeMapPinBasis('geocode'), 'coords');
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
        // 2026-10-05 후속 A: 서버 정의와 같은 (위도, 경도, 주소키) 조합 수.
        expect(raw['meta']['address_groups'], want['address_groups']);
        expect(payload.meta.addressGroups, want['address_groups']);
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

    test('standalone stats: 점 집합(lat,lng,total)이 벡터와 같다(한 번의 조회)', () async {
      // 모바일 Standalone 은 기존부터 화면 칸으로 점을 묶는다. 칸으로 묶기 직전의
      // (effective 위도, 경도, 주소키)별 건수를 지도 집계와 같은 표에서 한 번에 읽어
      // 서버 점 집합과 비교한다(명세 §7, Sol 1차 M5).
      final vectors = _vectors();
      await _seedVectors(vectors);
      final expected = vectors['expected'] as Map<String, dynamic>;
      for (final basis in ['coords', 'address']) {
        final want = {
          for (final p in ((expected[basis] as Map<String, dynamic>)['points']
              as List))
            '${(p['lat'] as num).toDouble()},${(p['lng'] as num).toDouble()},${p['total']}',
        };
        final rows = await LocalDbService.debugMapEffectivePoints(
          pinBasis: basis,
        );
        final got = {
          for (final r in rows)
            '${(r['lat'] as num).toDouble()},${(r['lng'] as num).toDouble()},${r['total']}',
        };
        expect(got, want, reason: basis);
        expect(rows, hasLength(want.length), reason: basis);
        // 지도 칸 집계도 같은 표를 쓴다: 전체 범위 한 번 조회의 건수 합 = 좌표 반영 건수.
        final raw = await LocalDbService.computeReportMapStats(pinBasis: basis);
        final payload = ReportMapPayload.fromJson(raw);
        expect(
          payload.points.fold<int>(0, (n, p) => n + p.total),
          (expected[basis] as Map<String, dynamic>)['geocoded_reports'],
          reason: basis,
        );
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
  
  group('Sol 1차 회귀', () {
    Future<void> insert(
      String id,
      Object? normalized,
      Object? place,
      Object? lat,
      Object? lng, {
      String status = '수용',
    }) async {
      final db = await LocalDbService.db;
      await db.insert('reports', {
        'ID': id,
        '신고번호': 'REG-$id',
        '신고일': '2026-01-01',
        '답변일': '2026-01-02',
        '위반장소': place,
        '주소정규화': normalized,
        '위도': lat,
        '경도': lng,
        '처리상태': status,
        'category': 'traffic',
      });
    }

    test('M1 탭·줄바꿈·NBSP 주소도 서버 strip 과 같은 주소키로 묶는다', () async {
      await insert('T1', '\t서울 중구\t', '\t서울 중구\t', 37.5, 127.0);
      await insert('T2', '서울 중구', '서울 중구', null, null);
      await insert('T3', '\n서울 중구\u00a0', '서울 중구', null, null);
      final address = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(pinBasis: 'address'),
      );
      expect(address.meta.geocodedReports, 3);
      expect(address.meta.missingReports, 0);
      expect(address.meta.addressGroups, 1);
      final points = await LocalDbService.debugMapEffectivePoints(
        pinBasis: 'address',
      );
      expect(points.single['addr_key'], '서울 중구');
      expect(points.single['total'], 3);
      final missing = ReportMapMissingPayload.fromJson(
        await LocalDbService.computeReportMapMissingGroups(pinBasis: 'address'),
      );
      expect(missing.reportCount, 0);
    });

    test('M2 같은 칸의 다른 좌표는 주소키가 달라도 묶음이다(coords·address)', () async {
      await insert('C1', 'A', '서울 중구', 37.5, 127.0);
      await insert('C2', 'B', '서울 중구', 37.6, 127.1);
      for (final basis in ['coords', 'address']) {
        final payload = ReportMapPayload.fromJson(
          await LocalDbService.computeReportMapStats(pinBasis: basis),
        );
        expect(payload.points, hasLength(1), reason: basis);
        expect(payload.points.single.isCluster, isTrue, reason: basis);
        expect(payload.points.single.total, 2, reason: basis);
      }
    });

    test('M2 칸 안 처리상태가 달라도 좌표가 다르면 묶음이다', () async {
      await insert('S1', 'A', '서울 중구', 37.5, 127.0, status: '수용');
      await insert('S2', 'A', '서울 중구', 37.6, 127.1, status: '불수용');
      final payload = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(),
      );
      expect(payload.points.single.isCluster, isTrue);
    });

    test('M2 같은 좌표·같은 장소 문구는 묶음이 아니다(기존 동작 유지)', () async {
      await insert('P1', 'A', '서울 중구', 37.5, 127.0, status: '수용');
      await insert('P2', 'A', '서울 중구', 37.5, 127.0, status: '불수용');
      final payload = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(),
      );
      expect(payload.points.single.isCluster, isFalse);
      expect(payload.points.single.total, 2);
    });

    test('M3 실수 좌표는 문자열이 아니라 숫자 그대로 센다', () async {
      await insert('F1', '서울 중구', '서울 중구', 37.5, 127.0);
      await insert('F2', '서울 중구', '서울 중구', 37.50000000000001, 127.0);
      final payload = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(),
      );
      expect(payload.meta.addressGroups, 2);
    });

    test('M6 대표 좌표 표는 DB 가 바뀌면 다시 만든다', () async {
      await insert('R1', '서울 중구', '서울 중구', null, null);
      var payload = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(pinBasis: 'address'),
      );
      expect(payload.meta.missingReports, 1);
      await insert('R2', '서울 중구', '서울 중구', 37.5, 127.0);
      payload = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(pinBasis: 'address'),
      );
      expect(payload.meta.geocodedReports, 2);
      expect(payload.meta.missingReports, 0);
    });

    test('2차 중간1 ID 가 NULL·빈 신고도 지도 건수·점에서 빠지지 않는다', () async {
      final db = await LocalDbService.db;
      for (final id in [null, null, '']) {
        await db.insert('reports', {
          'ID': id,
          '신고번호': 'NOID',
          '답변일': '2026-01-02',
          '위반장소': '서울 중구',
          '주소정규화': '서울 중구',
          '위도': 37.5,
          '경도': 127.0,
          'category': 'traffic',
        });
      }
      for (final basis in ['coords', 'address']) {
        final payload = ReportMapPayload.fromJson(
          await LocalDbService.computeReportMapStats(pinBasis: basis),
        );
        expect(payload.meta.totalReports, 3, reason: basis);
        expect(payload.meta.geocodedReports, 3, reason: basis);
        expect(payload.points.single.total, 3, reason: basis);
      }
    });

    test('2차 중간3 주소 모드 좌표 없는 목록은 지도와 같은 주소키로 묶는다', () async {
      await insert('W1', '서울  중구', '서울  중구', null, null);
      await insert('W2', '서울 중구', '서울 중구', null, null);
      final address = ReportMapMissingPayload.fromJson(
        await LocalDbService.computeReportMapMissingGroups(pinBasis: 'address'),
      );
      expect(address.groupCount, 2);
      expect(address.reportCount, 2);
    });

    test('2차 중간4 BOM 은 남기고 U+001C 는 지운다(서버 strip 과 같음)', () async {
      await insert('B1', '\uFEFF서울 중구', '\uFEFF서울 중구', 37.5, 127.0);
      await insert('B2', '서울 중구', '서울 중구', null, null);
      await insert('U1', '\u001C부산', '\u001C부산', 35.1, 129.0);
      await insert('U2', '부산', '부산', null, null);
      final payload = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(pinBasis: 'address'),
      );
      // 서울: BOM 키와 일반 키는 다른 주소 → B2 는 좌표 없음. 부산: 같은 주소 → U2 도 찍힘.
      expect(payload.meta.geocodedReports, 3);
      expect(payload.meta.missingReports, 1);
    });

    test('2차 중간4 BOM 주소: 좌표 없는 목록이 오류 없이 열리고 묶음 이름은 두 곳으로 센다', () async {
      await insert('M1', '\uFEFF대구', '\uFEFF대구', null, null);
      await insert('M2', '대구', '대구', null, null);
      final missing = ReportMapMissingPayload.fromJson(
        await LocalDbService.computeReportMapMissingGroups(pinBasis: 'address'),
      );
      expect(missing.groupCount, 2);
      expect(missing.groups.expand((g) => g.reports), hasLength(2));
      await insert('M3', '\uFEFF광주', '\uFEFF광주', 35.15, 126.85);
      await insert('M4', '광주', '광주', 35.16, 126.86);
      final payload = ReportMapPayload.fromJson(
        await LocalDbService.computeReportMapStats(),
      );
      final cell = payload.points.singleWhere((p) => p.total == 2);
      expect(cell.isCluster, isTrue);
      expect(cell.addressCount, 2);
    });

    test('L1 동률 주소는 코드포인트 순서로 고른다(서버 Python 과 같음)', () {
      const bmp = '서울 \uF900';
      const astral = '서울 \u{20000}';
      // UTF-16 비교로는 보조 평면 문자가 앞선다. 코드포인트로는 U+F900 이 앞선다.
      expect(astral.compareTo(bmp), lessThan(0));
      expect(LocalDbService.compareCodePoints(bmp, astral), lessThan(0));
      final label = LocalDbService.resolveMapClusterLabel([
        {'주소정규화': astral, '위반장소': astral},
        {'주소정규화': bmp, '위반장소': bmp},
      ]);
      expect(label.address, bmp);
      expect(label.region, '$bmp 외 1곳');
    });
  });
});
}
