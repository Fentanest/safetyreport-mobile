// 번호판 그룹핑 SQL 함수(normalize_plate) 보조 연결([PlateGroupSql]) 단위 시험.
// 공유 벡터(test/fixtures/plate_normalize_vectors.json)의 실데이터 사례로 묶음 규칙을 확인하고,
// 함수가 등록되지 않은 연결에서는 분명한 오류가 난다는 것, 그리고 보조 연결이 isolate 마다
// (main·WorkManager·그 밖의 백그라운드 isolate 와 같은 뜻) 독립적으로 스스로 등록한다는 것을 본다.
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/plate_group_sql.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3_lib;

void _seed(String path, List<String> plates) {
  final seed = sqlite3_lib.sqlite3.open(path);
  try {
    seed.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, plate TEXT)');
    for (final plate in plates) {
      seed.execute('INSERT INTO t(plate) VALUES (?)', [plate]);
    }
  } finally {
    seed.close();
  }
}

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sr_plate_group_sql_');
    path = '${dir.path}/plate.db';
  });

  tearDown(() {
    PlateGroupSql.closeAll();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test(
    '177도7967) 과 177도7967 은 한 그룹, 미인식끼리는 원문이 같을 때만 한 그룹',
    () {
      // plate_normalize_vectors.json: real_trailing_paren_3digit(177도7967) → 177도7967),
      // real_unrecognized_label(미인식 → null, 실패 시 원문 트림으로 자기 자신).
      _seed(path, [
        '177도7967)',
        '177도7967',
        '미인식',
        '미인식',
        '중앙선침범', // 다른 미인식 값 — 한 건뿐이라 중복 아님
        '12가3456',
      ]);
      final rows = PlateGroupSql.select(
        path,
        'SELECT plate, normalize_plate(plate) AS plate_key FROM t ORDER BY id',
      );
      final byPlate = {
        for (final r in rows) r['plate'] as String: r['plate_key'],
      };
      expect(byPlate['177도7967)'], '177도7967');
      expect(byPlate['177도7967'], '177도7967');
      expect(byPlate['미인식'], '미인식', reason: '정규화 실패 — 원문(트림) 그대로');
      expect(byPlate['중앙선침범'], '중앙선침범');
      expect(byPlate['12가3456'], '12가3456');

      final groups = PlateGroupSql.select(
        path,
        'SELECT normalize_plate(plate) AS plate_key, COUNT(*) AS n FROM t '
        'GROUP BY plate_key HAVING COUNT(*) >= 2 ORDER BY plate_key',
      );
      final counts = {
        for (final r in groups) r['plate_key'] as String: r['n'] as int,
      };
      expect(counts['177도7967'], 2, reason: '군더더기 ")" 차이만 있는 두 표기가 한 그룹');
      expect(counts['미인식'], 2, reason: '같은 미인식 원문 두 건');
      expect(
        counts.containsKey('중앙선침범'),
        isFalse,
        reason: '다른 미인식 값은 한 건뿐이라 중복 그룹이 아니다',
      );
    },
  );

  test('트림 규칙: 실패 시 원문 앞뒤 공백만 지우고 안은 그대로', () {
    _seed(path, ['  미인식  ', '미인식']);
    final rows = PlateGroupSql.select(
      path,
      'SELECT plate, normalize_plate(plate) AS plate_key FROM t ORDER BY id',
    );
    expect(rows.every((r) => r['plate_key'] == '미인식'), isTrue);
  });

  test(
    'normalize_plate 를 등록하지 않은 보통 연결(package:sqlite3)에서 그 함수를 쓰면 '
    '조용히 틀리지 않고 분명한 오류로 멈춘다',
    () {
      _seed(path, ['12가3456']);
      final bare = sqlite3_lib.sqlite3.open(
        path,
        mode: sqlite3_lib.OpenMode.readOnly,
      );
      addTearDown(bare.close);
      expect(
        () => bare.select('SELECT normalize_plate(plate) FROM t'),
        throwsA(
          isA<sqlite3_lib.SqliteException>().having(
            (e) => e.toString(),
            'message',
            contains('no such function'),
          ),
        ),
      );
    },
  );

  test('DB 파일 경로마다 보조 연결을 하나만 열고 캐시한다', () {
    _seed(path, []);
    PlateGroupSql.select(path, 'SELECT 1');
    expect(PlateGroupSql.openConnectionCountForTest, 1);
    PlateGroupSql.select(path, 'SELECT 1');
    expect(PlateGroupSql.openConnectionCountForTest, 1, reason: '같은 경로는 재사용');
    PlateGroupSql.closeAll();
    expect(PlateGroupSql.openConnectionCountForTest, 0);
  });

  test('백그라운드 isolate 도 스스로 함수를 등록해 같은 결과를 낸다', () async {
    _seed(path, ['177도7967)']);
    // WorkManager·그 밖의 백그라운드 isolate 와 같은 뜻 — static 캐시가 isolate 마다 따로라
    // 새 isolate 는 부모와 무관하게 처음 쓸 때 스스로 연결을 열고 등록해야 한다.
    final key = await Isolate.run(
      () => PlateGroupSql.select(
        path,
        'SELECT normalize_plate(plate) AS plate_key FROM t',
      ).single['plate_key'],
    );
    expect(key, '177도7967');
  });
}
