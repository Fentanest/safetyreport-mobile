// SQ-P03: 엑셀 내보내기를 페이지 읽기 + 작업자 isolate 로 옮긴 뒤에도 통합 문서 내용이 예전과 같은지 본다.
// "예전 경로"는 f27c7899 의 file_browser_screen._exportExcel/_fillSheet 를 그대로 옮긴 것이다.
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/excel_export_service.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── 예전 경로(그대로 복사) ─────────────────────────────────────────────────

void _legacyFillSheet(
  Excel excel,
  String sheetName,
  List<Report> reports,
  Set<String> watchlist,
) {
  final sheet = excel[sheetName];

  // 첨부사진/첨부파일 URL 목록 분리
  final photoLists = reports
      .map(
        (r) => r.attachedPhotos.isEmpty
            ? <String>[]
            : r.attachedPhotos
                  .split('\n')
                  .where((s) => s.trim().isNotEmpty)
                  .toList(),
      )
      .toList();
  final fileLists = reports
      .map(
        (r) => r.attachedFiles.isEmpty
            ? <String>[]
            : r.attachedFiles
                  .split('\n')
                  .where((s) => s.trim().isNotEmpty)
                  .toList(),
      )
      .toList();

  final maxPhotos = photoLists.fold<int>(
    0,
    (m, l) => l.length > m ? l.length : m,
  );
  final maxFiles = fileLists.fold<int>(
    0,
    (m, l) => l.length > m ? l.length : m,
  );

  final headers = <String>[
    'ID',
    '상태',
    '신고번호',
    '신고명',
    '신고일',
    '처리상태',
    '차량번호',
    '위반법규',
    '범칙금_과태료',
    '벌점',
    '처리기관',
    '담당자',
    '답변일',
    '발생일자',
    '발생시각',
    '위반장소',
    '종결여부',
    '신고내용',
    '처리내용',
    '지도',
    for (var i = 1; i <= maxPhotos; i++) '첨부사진$i',
    for (var i = 1; i <= maxFiles; i++) '첨부파일$i',
    '만족도조사여부',
    '별점',
    '별점사유',
    '감시목록',
  ];

  for (var col = 0; col < headers.length; col++) {
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0))
        .value = TextCellValue(
      headers[col],
    );
  }

  for (var row = 0; row < reports.length; row++) {
    final r = reports[row];
    final photos = photoLists[row];
    final files = fileLists[row];
    final values = <String>[
      r.id,
      r.result,
      r.reportNumber,
      r.name,
      r.date,
      r.status,
      r.carNumber,
      r.law,
      r.fineInfo,
      r.penaltyPoints,
      r.agency,
      r.manager,
      r.responseDate,
      r.occurrenceDate,
      r.occurrenceTime,
      r.location,
      r.processingFinish,
      r.reportContent,
      r.processContent,
      r.mapImage,
      for (var i = 0; i < maxPhotos; i++) i < photos.length ? photos[i] : '',
      for (var i = 0; i < maxFiles; i++) i < files.length ? files[i] : '',
      r.pollStatus,
      r.rating?.toString() ?? '',
      r.ratingCause,
      watchlist.contains(r.reportNumber) ? 'Y' : 'N',
    ];
    for (var col = 0; col < values.length; col++) {
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row + 1))
          .value = TextCellValue(
        values[col],
      );
    }
  }
}

Future<List<int>> _legacyWorkbook({required bool excludeWithdraw}) async {
  final ew = excludeWithdraw;
  final tReports = await LocalDbService.getReportsByCategory(
    'traffic',
    excludeWithdraw: ew,
  );
  final pReports = await LocalDbService.getReportsByCategory(
    'parking',
    excludeWithdraw: ew,
  );
  final oReports = await LocalDbService.getReportsByCategory(
    'other',
    excludeWithdraw: ew,
  );
  final watchlist = await LocalDbService.getWatchlistNumbers();

  final excel = Excel.createExcel();
  _legacyFillSheet(excel, '교통위반', tReports, watchlist);
  _legacyFillSheet(excel, '주정차위반', pReports, watchlist);
  _legacyFillSheet(excel, '기타위반', oReports, watchlist);
  excel.delete('Sheet1');
  final bytes = excel.encode();
  if (bytes == null) throw Exception('Excel 인코딩 실패');
  return bytes;
}

// ── 고정 DB ────────────────────────────────────────────────────────────────

String? _pick(int i, List<String?> values) => values[i % values.length];

Map<String, Object?> _row(String category, int i) {
  final id =
      '${category[0].toUpperCase()}${(i * 7919 % 100000).toString().padLeft(5, '0')}';
  // 동률 신고번호(정렬 안정성), NULL·빈 신고번호를 섞는다.
  final number = i % 11 == 0
      ? null
      : i % 13 == 0
      ? ''
      : 'SPP-2026-${((i ~/ 3) * 37 % 5000).toString().padLeft(7, '0')}';
  return {
    'ID': id,
    'category': category,
    '신고번호': number,
    '상태': _pick(i, [null, '', '수용', '불수용', '처리중']),
    '신고명': _pick(i, ['신호위반', '불법주정차 (소화전 앞)', null, '']),
    '신고일': '2026-0${1 + i % 9}-${(1 + i % 28).toString().padLeft(2, '0')}',
    '만족도조사여부': _pick(i, [null, '', '참여 완료', '답변 대기', '미참여']),
    '별점': i % 4 == 0 ? null : (i % 5) + 1,
    '별점사유': _pick(i, ['', null, '친절한 답변\n감사합니다', '"따옴표" & <꺾쇠>']),
    '처리상태': _pick(i, ['수용', '불수용', '취하', null, '', '처리중', '수용']),
    '차량번호': _pick(i, ['12가3456', null, '', '서울31바5845']),
    '위반법규': _pick(i, ['도로교통법 제5조', '도로교통법 제32조', null, '']),
    '범칙금_과태료': _pick(i, [
      '과태료: 40,000원',
      '범칙금: 30,000원 / 벌점: 15점',
      '경고',
      null,
      '',
      '미확인',
    ]),
    '벌점': _pick(i, ['15', '', null, '0']),
    '처리기관': _pick(i, ['서울특별시 강서경찰서 교통과', '부천시청 교통행정과', null, '']),
    '처리기관코드': _pick(i, [null, '', '1320000']),
    '담당자': _pick(i, ['홍길동', null, '', '김 담당 (031-000-0000)']),
    '답변일': _pick(i, ['2026-03-01', '2026-03-02 14:05:00', null, '']),
    '발생일자': _pick(i, ['2026-02-28', null, '']),
    '발생시각': _pick(i, ['08:10', '23:59:59', null, '']),
    '위반장소': _pick(i, ['경기도 부천시 원미구 길주로 000', null, '', '서울 강서구\n공항대로 1']),
    '종결여부': _pick(i, [null, 'Y', 'N', '']),
    '신고내용': _pick(i, [
      '여러 줄\n신고 내용\r\n세 번째 줄',
      null,
      '',
      '  앞뒤 공백  ',
      '이모지 🚗 와 탭\t문자',
    ]),
    '처리내용': _pick(i, ['과태료 부과 예정입니다.\n\n담당: 교통과', null, '', '1234.50']),
    '지도': _pick(i, ['https://example.test/map/$i.png', null, '']),
    '첨부사진': _pick(i, [
      null,
      '',
      'https://example.test/p/$i-1.jpg',
      'https://example.test/p/$i-1.jpg\n\nhttps://example.test/p/$i-2.jpg\n  \nhttps://example.test/p/$i-3.jpg',
    ]),
    '첨부파일': _pick(i, [
      '',
      null,
      'https://example.test/f/$i.mp4\nhttps://example.test/f/$i.mov',
    ]),
    '감시목록': i % 9 == 0 ? 'Y' : 'N',
    // 내보내지 않는 큰 열(필요한 열만 읽는지와 무관하게 결과가 같아야 한다)
    'raw_content': 'x' * 200,
    'synced_at': 1700000000000 + i,
  };
}

Future<Set<String>> _seedFixture() async {
  final d = await LocalDbService.db;
  final batch = d.batch();
  final numbers = <String>{};
  // 1,400건(취하 제외 후에도 1,000건 초과) → 1,000행 페이지 2개, 32건 넘는 정렬(동률 신고번호 포함).
  for (var i = 0; i < 1400; i++) {
    final row = _row('traffic', i);
    batch.insert('reports', row);
    if (row['신고번호'] case final String n when n.isNotEmpty) numbers.add(n);
  }
  for (var i = 0; i < 57; i++) {
    batch.insert('reports', _row('parking', i));
  }
  for (var i = 0; i < 5; i++) {
    batch.insert('reports', _row('other', i));
  }
  // 내보내지 않는 분류
  batch.insert('reports', _row('duplicate', 1));
  await batch.commit(noResult: true);

  final traffic = await d.query(
    'reports',
    columns: ['ID'],
    where: 'category = ?',
    whereArgs: ['traffic'],
    orderBy: 'ID',
    limit: 6,
  );
  final ids = traffic.map((r) => r['ID'] as String).toList();
  // 사용자 수정값(보기에서 COALESCE): 값·빈 문자열·NULL 수정값.
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final (id, column, value) in [
    (ids[0], '처리상태', '수용'),
    (ids[0], '범칙금_과태료', '과태료: 70,000원(수정)'),
    (ids[1], '신고내용', ''),
    (ids[2], '처리내용', null),
    (ids[3], '처리상태', '취하'),
  ]) {
    await d.insert('report_override', {
      'ID': id,
      'column_name': column,
      'value': value,
      'updated_at': now,
    });
  }
  // 확정 중복군(대표 1 + 구성원 2). 내보내기는 대표건 투영을 하지 않으므로 모두 남아야 한다.
  await d.insert('duplicate_group', {
    'group_id': 'g1',
    'fingerprint': 'fp',
    'match_type': 'field',
    'status': 'confirmed_duplicate',
    'member_count': 3,
  });
  for (var k = 0; k < 3; k++) {
    await d.insert('duplicate_member', {
      'group_id': 'g1',
      'report_id': ids[k],
      'report_number': 'SPP-DUP',
      'category': 'traffic',
      'is_representative': k == 0 ? 1 : 0,
    });
  }
  final watch = numbers.take(40).toSet()..add('SPP-NOT-IN-DB');
  await LocalDbService.setWatchlistNumbers(watch);
  return watch;
}

// ── 비교 ───────────────────────────────────────────────────────────────────

void _expectSameWorkbook(List<int> legacyBytes, List<int> newBytes) {
  // 압축 결과 길이까지 같다(zip 항목 시각만 다를 수 있다).
  expect(newBytes.length, legacyBytes.length, reason: 'encoded size');
  final legacy = Excel.decodeBytes(legacyBytes);
  final current = Excel.decodeBytes(newBytes);
  expect(current.tables.keys.toList(), legacy.tables.keys.toList());
  expect(legacy.tables.keys.toList(), ['교통위반', '주정차위반', '기타위반']);
  expect(current.getDefaultSheet(), legacy.getDefaultSheet());
  for (final name in legacy.tables.keys) {
    final a = legacy.tables[name]!;
    final b = current.tables[name]!;
    expect(b.maxRows, a.maxRows, reason: '$name rows');
    expect(b.maxColumns, a.maxColumns, reason: '$name columns');
    for (var r = 0; r < a.maxRows; r++) {
      final ra = a.rows[r];
      final rb = b.rows[r];
      expect(rb.length, ra.length, reason: '$name row $r length');
      for (var c = 0; c < ra.length; c++) {
        final ca = ra[c];
        final cb = rb[c];
        expect(
          cb?.value.runtimeType,
          ca?.value.runtimeType,
          reason: '$name R${r}C$c type',
        );
        expect(
          cb?.value?.toString(),
          ca?.value?.toString(),
          reason: '$name R${r}C$c',
        );
        expect(cb?.cellStyle, ca?.cellStyle, reason: '$name R${r}C$c style');
      }
    }
  }
}

List<String> _header(List<int> bytes, String sheet) => Excel.decodeBytes(
  bytes,
).tables[sheet]!.rows.first.map((c) => c?.value?.toString() ?? '').toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Set<String> watchlist;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_excel_export_');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
    watchlist = await _seedFixture();
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  for (final excludeWithdraw in [false, true]) {
    test(
      'paged/isolate workbook equals the legacy workbook (excludeWithdraw=$excludeWithdraw)',
      () async {
        final legacy = await _legacyWorkbook(excludeWithdraw: excludeWithdraw);
        final current = await ExcelExportService.buildWorkbookBytes(
          excludeWithdraw: excludeWithdraw,
        );
        _expectSameWorkbook(legacy, current);

        // 비교가 빈 문서끼리의 비교가 아님을 확인한다.
        final book = Excel.decodeBytes(current);
        final traffic = book.tables['교통위반']!;
        final d = await LocalDbService.db;
        final expectedTraffic =
            (await d.rawQuery(
                  'SELECT COUNT(*) AS n FROM reports_effective WHERE category = ?'
                  "${excludeWithdraw ? " AND IFNULL(처리상태, '') != '취하'" : ''}",
                  ['traffic'],
                )).first['n']
                as int;
        expect(traffic.maxRows, expectedTraffic + 1);
        expect(expectedTraffic, greaterThan(1000));
        expect(book.tables['기타위반']!.maxRows, greaterThan(1));
        final header = _header(current, '교통위반');
        expect(
          header,
          containsAllInOrder(['범칙금_과태료', '첨부사진1', '첨부사진3', '첨부파일2', '감시목록']),
        );
        // 확정 금액 열은 원문 하나뿐이고 추정 금액 열을 섞지 않는다.
        expect(header.where((h) => h.contains('과태료')), ['범칙금_과태료']);
        expect(header.where((h) => h.contains('추정')), isEmpty);
        final values = traffic.rows
            .skip(1)
            .expand((r) => r)
            .map((c) => c?.value?.toString() ?? '')
            .toSet();
        expect(values, contains('과태료: 70,000원(수정)'));
        expect(values, contains('여러 줄\n신고 내용\r\n세 번째 줄'));
        expect(values, contains('답변 대기')); // NULL 만족도조사여부의 기본값
        final watchColumn = header.indexOf('감시목록');
        final watchedRows = traffic.rows
            .skip(1)
            .where((r) => r[watchColumn]?.value?.toString() == 'Y')
            .length;
        expect(watchedRows, greaterThan(0));
        expect(watchlist, isNotEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test('export reads only the sheet columns in ID pages', () async {
    final pages = <int>[];
    await LocalDbService.readReportsForExport(
      'traffic',
      onPage: (page) {
        pages.add(page.length);
        // 시트에 쓰지 않는 열은 읽지 않는다(예: category, synced_at).
        expect(
          page.every((r) => r.category.isEmpty && r.syncedAt == null),
          isTrue,
        );
      },
    );
    expect(pages, [1000, 400]);
    expect(LocalDbService.exportReportColumns, isNot(contains('raw_content')));
    expect(LocalDbService.exportReportColumns, isNot(contains('category')));
  });

  group('exportToDirectory', () {
    late Directory out;
    setUp(() => out = Directory.systemTemp.createTempSync('sr_excel_out_'));
    tearDown(() => out.deleteSync(recursive: true));

    test('reports progress and publishes exactly one finished file', () async {
      final progress = <ExcelExportProgress>[];
      final file = await ExcelExportService.exportToDirectory(
        out,
        excludeWithdraw: true,
        onProgress: progress.add,
        clock: () => DateTime(2026, 10, 4, 9, 8, 7),
      );
      expect(file.path, '${out.path}/안전신문고_20261004_090807.xlsx');
      expect(out.listSync().map((e) => e.path.split('/').last), [
        '안전신문고_20261004_090807.xlsx',
      ]);
      final reading = progress
          .where((p) => p.phase == ExcelExportPhase.reading)
          .toList();
      expect(reading.first.done, 0);
      expect(reading.last.done, reading.last.total);
      for (var i = 1; i < reading.length; i++) {
        expect(reading[i].done, greaterThanOrEqualTo(reading[i - 1].done));
      }
      expect(progress.map((p) => p.phase).toSet(), {
        ExcelExportPhase.reading,
        ExcelExportPhase.building,
        ExcelExportPhase.saving,
      });
      final legacy = await _legacyWorkbook(excludeWithdraw: true);
      _expectSameWorkbook(legacy, await file.readAsBytes());
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('cancel while reading leaves no file', () async {
      final cancel = ExcelExportCancelToken();
      await expectLater(
        ExcelExportService.exportToDirectory(
          out,
          excludeWithdraw: false,
          cancel: cancel,
          onProgress: (p) {
            if (p.phase == ExcelExportPhase.reading && p.done > 0) {
              cancel.cancel();
            }
          },
        ),
        throwsA(isA<ExcelExportCancelled>()),
      );
      expect(out.listSync(), isEmpty);
    });

    test('cancel while building kills the worker and leaves no file', () async {
      final cancel = ExcelExportCancelToken();
      await expectLater(
        ExcelExportService.exportToDirectory(
          out,
          excludeWithdraw: false,
          cancel: cancel,
          onProgress: (p) {
            if (p.phase == ExcelExportPhase.building) cancel.cancel();
          },
        ),
        throwsA(isA<ExcelExportCancelled>()),
      );
      expect(out.listSync(), isEmpty);
    });
  });
}
