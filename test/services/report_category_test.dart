import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/report_category.dart' as rc;

void main() {
  final contractFile = File('contracts/report-categories.json');
  final contract =
      jsonDecode(contractFile.readAsStringSync()) as Map<String, dynamic>;

  test('categories and labels match contract', () {
    final items = contract['categories'] as List;
    expect(rc.categories, items.map((c) => c['key']).toList());
    expect(rc.categoryLabels, {for (final c in items) c['key']: c['label']});
  });

  test('groups match contract', () {
    expect(rc.groupCategory, {
      for (final g in contract['groups']) g['cd']: g['category'],
    });
  });

  test('codes match contract', () {
    expect(rc.codes, {
      for (final c in contract['codes'])
        (c['cd'] as String, c['type'] as String): (
          name: c['name'] as String,
          category: c['category'] as String,
        ),
    });
    expect(rc.codes.length, 43);
  });

  test('menus and aliases match contract', () {
    final entries = contract['entry_value'];
    // Compare JSON-shaped values so lists inside records use deep equality.
    expect(
      {
        for (final m in rc.entryMenus.entries)
          m.key: {'cds': m.value.cds, 'category': m.value.category},
      },
      {
        for (final m in entries['menus'])
          m['menu']: {'cds': m['cds'], 'category': m['category']},
      },
    );
    expect(rc.entryAliases, {
      for (final a in entries['aliases'])
        ((a['cds'] as List).join('|'), a['sub'] as String): (
          (a['code'] as String).split('-')[0],
          (a['code'] as String).split('-')[1],
        ),
    });
  });

  for (final v in contract['vectors']) {
    test('vector: ${v['name']}', () {
      final got = rc.resolve(v['ssnpc_cd'], v['ssnpc_type'], v['entry_value']);
      expect(got.code, v['expect']['code']);
      expect(got.category, v['expect']['category']);
      expect(
        rc.categoryOf(v['ssnpc_cd'], v['ssnpc_type'], v['entry_value']),
        got.category,
      );
      if (got.code != null) {
        expect('${got.ssnpcCd}-${got.ssnpcType}', got.code);
      }
    });
  }

  test('Python whitespace set is removed, BOM is preserved', () {
    const whitespace = [
      0x09,
      0x0a,
      0x0b,
      0x0c,
      0x0d,
      0x1c,
      0x1d,
      0x1e,
      0x1f,
      0x20,
      0x85,
      0xa0,
      0x1680,
      0x2000,
      0x2001,
      0x2002,
      0x2003,
      0x2004,
      0x2005,
      0x2006,
      0x2007,
      0x2008,
      0x2009,
      0x200a,
      0x2028,
      0x2029,
      0x202f,
      0x205f,
      0x3000,
    ];
    for (final point in whitespace) {
      final space = String.fromCharCode(point);
      expect(
        rc.resolve('${space}i${space}p$space', '${space}5$space').code,
        'IP-05',
      );
      expect(
        rc
            .resolve(null, null, '불법$space주정차신고-소방차$space전용구역$space불법주차')
            .code,
        'EP-03',
      );
    }
    expect(rc.normalizeCode('\ufeffip', 5).ssnpcCd, '\ufeffIP');
    expect(rc.resolve(null, null, '\ufeff불법주정차신고-인도').category, 'other');
    expect(rc.resolve(null, null, '안전신고-쓰레기, 폐기물, 유독물').code, 'CM-05');
  });

  test('normalization preserves unknown codes and Python digit padding', () {
    expect(rc.normalizeCode(' ip ', 3), (ssnpcCd: 'IP', ssnpcType: '03'));
    expect(rc.normalizeCode(null, 0), (ssnpcCd: null, ssnpcType: null));
    for (final digit in ['²', '٣', '３', '\u{1d7d9}']) {
      expect(rc.normalizeCode('xx', digit).ssnpcType, '0$digit');
    }
    expect(rc.normalizeCode('xx', 'ab').ssnpcType, 'ab');
    expect(rc.normalizeCode('xx', '123').ssnpcType, '123');
    expect(rc.resolve('xx', '3', '불법주정차신고-인도'), (
      ssnpcCd: 'XX',
      ssnpcType: '03',
      code: null,
      category: 'other',
    ));
    expect(rc.resolve(null, '99', '불법주정차신고-인도').code, 'IP-06');
  });

  test('codeName', () {
    expect(rc.codeName('IP-05'), '어린이보호구역');
    expect(rc.codeName('CM-05'), '(구)쓰레기, 폐기물, 유독물');
    expect(rc.codeName('XX-01'), '');
    expect(rc.codeName('IP'), '');
    expect(rc.codeName(null), '');
  });

  // 서버 레포가 옆에 있을 때만(작업 worktree 는 이름이 달라 건너뛴다)
  final serverCopies = [
    File('../safetyreport/contracts/report-categories.json'),
  ];
  final available = serverCopies.where((file) => file.existsSync()).toList();
  test('server contract sha256 matches', () {
    for (final server in available) {
      expect(
        sha256.convert(contractFile.readAsBytesSync()).toString(),
        sha256.convert(server.readAsBytesSync()).toString(),
        reason: server.path,
      );
    }
  }, skip: available.isEmpty ? '서버 레포 없음' : false);
}
