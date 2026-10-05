// 지도 묶음 원(cluster) 이름 — contracts/map-cluster-label-vectors.json(서버와 바이트 동일).
// Standalone 칸 점(_MapCellAccumulator)의 address/address_count/region 이
// 벡터 description 규칙과 같은지 본다. 칸 이름 계산을 순수 함수
// (LocalDbService.resolveMapClusterLabel)로 빼서 벡터로 직접 검증하고,
// 실제 computeReportMapStats 로 칸 하나 이상이 같은 결과를 내는지도 확인한다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report_map.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> _vectors() => jsonDecode(
  File('contracts/map-cluster-label-vectors.json').readAsStringSync(),
) as Map<String, dynamic>;

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

Future<void> _seedCell(List<dynamic> rows, {required double lat, required double lng}) async {
  final db = await LocalDbService.db;
  var i = 0;
  for (final row in rows) {
    final r = row as Map;
    i++;
    await db.insert('reports', {
      'ID': 'CELL-$i',
      '신고번호': 'CELL-$i',
      '신고일': '2026-01-01',
      '답변일': '2026-01-02',
      '위반장소': r['위반장소'],
      '주소정규화': r['주소정규화'],
      '위도': lat,
      '경도': lng,
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
    await databaseFactory.setDatabasesPath(
      (tempDbDir = Directory.systemTemp.createTempSync('sr_cluster_label_test_'))
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

  test('pure: 칸 이름 계산이 벡터 5셀과 같다', () {
    final vectors = _vectors();
    for (final cell in (vectors['cells'] as List)) {
      final c = cell as Map;
      final rows = [
        for (final r in (c['rows'] as List)) Map<String, Object?>.from(r as Map),
      ];
      final want = c['expected'] as Map;
      final got = LocalDbService.resolveMapClusterLabel(rows);
      expect(got.address, want['address'], reason: '${c['name']} address');
      expect(
        got.addressCount,
        want['address_count'],
        reason: '${c['name']} address_count',
      );
      expect(got.region, want['region'], reason: '${c['name']} region');
    }
  });

  test('pure: 동률이면 문자열 비교로 작은 키, 표시는 최소 trim(위반장소)', () {
    // 벡터 'tie takes the smaller key' 와 'one key, smallest display text' 를
    // 공백·null 변형으로도 확인한다.
    final tie = LocalDbService.resolveMapClusterLabel([
      {'주소정규화': '서울 마포구 상암동 2 ', '위반장소': '서울 마포구 상암동 2'},
      {'주소정규화': '서울 마포구 상암동 2', '위반장소': '서울 마포구 상암동 2'},
      {'주소정규화': '서울 마포구 망원동 3', '위반장소': '서울 마포구 망원동 3'},
      {'주소정규화': '서울 마포구 망원동 3', '위반장소': '서울 마포구 망원동 3'},
    ]);
    expect(tie.address, '서울 마포구 망원동 3');
    expect(tie.addressCount, 2);
    expect(tie.region, '서울 마포구 망원동 3 외 1곳');

    final disp = LocalDbService.resolveMapClusterLabel([
      {'주소정규화': '대구 중구 동인동 1', '위반장소': '대구 중구 동인동1번지'},
      {'주소정규화': '대구 중구 동인동 1', '위반장소': ' 대구 중구 동인동 1번지 '},
    ]);
    expect(disp.address, '대구 중구 동인동 1번지');
    expect(disp.addressCount, 1);
    expect(disp.region, '대구 중구 동인동 1번지');
  });

  test('standalone: 같은 칸 조회가 벡터와 같은 address/address_count/region 을 낸다', () async {
    final vectors = _vectors();
    final cells = vectors['cells'] as List;
    final first = cells.firstWhere(
      (c) => (c as Map)['name'] == 'most reported address wins',
    ) as Map;
    await _seedCell(
      first['rows'] as List,
      lat: 37.5,
      lng: 127.0,
    );
    final raw = await LocalDbService.computeReportMapStats();
    final payload = ReportMapPayload.fromJson(raw);
    expect(payload.points, hasLength(1));
    final point = payload.points.single;
    final want = first['expected'] as Map;
    expect(point.total, (first['rows'] as List).length);
    expect(point.isCluster, isTrue);
    expect(point.address, want['address']);
    expect(point.addressCount, want['address_count']);
    expect(point.region, want['region']);
    // 원시 JSON 에도 하위호환 추가 필드로 있다.
    final jsonPoint =
        (raw['points'] as List).single as Map<String, dynamic>;
    expect(jsonPoint['address'], want['address']);
    expect(jsonPoint['address_count'], want['address_count']);
    expect(jsonPoint['region'], want['region']);
  });

  test('standalone: 주소 없는 칸도 벡터와 같다', () async {
    final vectors = _vectors();
    final cells = vectors['cells'] as List;
    final cell = cells.firstWhere(
      (c) => (c as Map)['name'] == 'no address at all',
    ) as Map;
    await _seedCell(cell['rows'] as List, lat: 37.5, lng: 127.0);
    final payload = ReportMapPayload.fromJson(
      await LocalDbService.computeReportMapStats(),
    );
    expect(payload.points, hasLength(1));
    final point = payload.points.single;
    final want = cell['expected'] as Map;
    expect(point.address, want['address']);
    expect(point.addressCount, want['address_count']);
    expect(point.region, want['region']);
  });

  test('model: address_count 없으면 0 (하위호환)', () {
    ReportMapPoint p(Map<String, dynamic> json) => ReportMapPoint.fromJson(json);
    Map<String, dynamic> base() => {
      'lat': 37.5,
      'lng': 127.0,
      'address': '서울특별시 강남구 테헤란로 1',
      'region': '',
      'total': 1,
    };
    expect(p(base()).addressCount, 0);
    expect(p({...base(), 'address_count': 3}).addressCount, 3);
    expect(p({...base(), 'address_count': '2'}).addressCount, 2);
  });
}
