import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:safetyreport/services/law_values.dart';
import 'package:safetyreport/services/fine_estimate.dart' as fine;

void main() {
  final cases =
      (jsonDecode(File('contracts/law-search-vectors.json').readAsStringSync())
              as Map)['cases']
          as List;
  for (final c in cases) {
    test('search ${c['name']}', () {
      expect(matchesLaws(c['value'], c['query'] as String), c['expected']);
    });
  }
  test('parser to per-member search and stable dedup', () {
    final value = parseViolationLaw(
      '도로교통법 제32조, 제33조, 제34조 위반. 신고된 차량에 대해 과태료부과 처분을 하였습니다.',
    );
    expect(readLaws(value), ['도로교통법 제32조', '도로교통법 제33조', '도로교통법 제34조']);
    expect(readLaws('$value\n도로교통법 제33조'), readLaws(value));
    for (final q in readLaws(value)) {
      expect(matchesLaws(value, q), true);
    }
  });
  test('secondary citation does not change money', () {
    final row = <String, dynamic>{
      'category': 'traffic',
      '차량번호': '12가3456',
      '위반법규': '도로교통법 제23조',
      'ssnpc_cd': 'TV',
      'ssnpc_type': '09',
    };
    final multi = {...row, '위반법규': '${row['위반법규']}\n도로교통법 제5조'};
    for (final text in ['과태료: 40,000원', '과태료: 7,0000원', '과태료']) {
      expect(
        fine.extractFineAmount(text, multi),
        fine.extractFineAmount(text, row),
      );
      expect(
        fine.estimateIfUnknown(text, multi),
        fine.estimateIfUnknown(text, row),
      );
    }
  });
  test(
    'exact SQL after distinct-value matching, including quotes and empty values',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      try {
        await db.execute(
          'CREATE TABLE reports (id INTEGER PRIMARY KEY, law TEXT)',
        );
        for (var i = 0; i < cases.length; i++) {
          await db.insert('reports', {'id': i, 'law': cases[i]['value']});
        }
        final distinct = (await db.rawQuery(
          'SELECT DISTINCT CAST(law AS BLOB) AS law FROM reports',
        )).map((r) => lawSqlRawValue(r['law'])).toList();
        for (var i = 0; i < cases.length; i++) {
          final q = cases[i]['query'] as String;
          final values = distinct.where((v) => matchesLaws(v, q));
          final got = await db.rawQuery(
            'SELECT id FROM reports WHERE ${lawSqlValues('law', values)}',
          );
          expect(
            got.any((r) => r['id'] == i),
            cases[i]['expected'],
            reason: cases[i]['name'] as String,
          );
        }
        final values = List.generate(1500, (i) => "합성 법규 '$i");
        await db.insert('reports', {'id': 2000, 'law': values.last});
        expect(
          await db.rawQuery(
            'SELECT id FROM reports WHERE ${lawSqlValues('law', values)}',
          ),
          [
            {'id': 2000},
          ],
        );
        expect(
          (await db.rawQuery('SELECT count(*) AS n FROM reports')).single['n'],
          cases.length + 1,
        );
      } finally {
        await db.close();
      }
    },
  );
}
