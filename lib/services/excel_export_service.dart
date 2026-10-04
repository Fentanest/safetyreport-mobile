import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import '../models/report.dart';
import 'local_db_service.dart';
import 'performance_trace.dart' show QueryCancelled;

/// Standalone 파일 화면의 "Excel 내보내기"(SQ-P03).
///
/// 출력은 예전 화면 코드와 같다: 시트 교통위반·주정차위반·기타위반(이 순서), 같은 열·같은 값,
/// 모든 셀은 문자열(TextCellValue). 확정 과태료는 `범칙금_과태료` 원문 그대로이고 추정 금액 열은 없다.
///
/// 설계:
/// - sqflite 는 일반 isolate 에서 쓸 수 없고 공유 연결·close guard([LocalDbService.runBackgroundWork])를
///   그대로 쓰려면 읽기는 UI isolate 에 남아야 한다. 그래서 UI isolate 는 필요한 열만 ID keyset 1,000행씩
///   읽어 페이지를 문자열 행으로 바꿔 작업자 isolate 로 보내고, 그 페이지를 버린다.
/// - 작업자는 시트별 문자열 행을 모았다가 예전과 같은 순서(ID 오름차순 → 신고번호 내림차순 `List.sort`)로
///   정렬하고, 같은 셀 쓰기 순서로 통합 문서를 만들어 `encode()` 한 뒤 바이트를 [Isolate.exit] 로 넘긴다.
/// - 취소는 페이지 경계(읽기) 또는 즉시(작업자 kill)이며, 파일은 `.part` 에 다 쓴 뒤에만 최종 이름으로 바꾼다.
class ExcelExportService {
  ExcelExportService._();

  /// (category, 시트 이름) — 예전과 같은 순서.
  static const sheets = <(String, String)>[
    ('traffic', '교통위반'),
    ('parking', '주정차위반'),
    ('other', '기타위반'),
  ];

  static final _fileStamp = DateFormat('yyyyMMdd_HHmmss');

  /// 저장 파일 이름(예전과 같은 형식).
  static String fileNameFor(DateTime time) =>
      '안전신문고_${_fileStamp.format(time)}.xlsx';

  /// 통합 문서 바이트를 만든다. UI isolate 는 페이지 읽기·전달만 한다.
  static Future<Uint8List> buildWorkbookBytes({
    required bool excludeWithdraw,
    ExcelExportCancelToken? cancel,
    void Function(ExcelExportProgress progress)? onProgress,
  }) async {
    bool cancelled() => cancel?.isCancelled == true;
    void checkCancel() {
      if (cancelled()) throw const ExcelExportCancelled();
    }

    checkCancel();
    var total = 0;
    for (final (category, _) in sheets) {
      total += await LocalDbService.countReportsForExport(
        category,
        excludeWithdraw: excludeWithdraw,
      );
      checkCancel();
    }
    var done = 0;
    onProgress?.call(
      ExcelExportProgress(ExcelExportPhase.reading, done: 0, total: total),
    );

    final worker = await _ExportWorker.spawn();
    try {
      final cancelSub = cancel?._whenCancelled.then((_) => worker.kill());
      unawaited(cancelSub);
      for (var i = 0; i < sheets.length; i++) {
        try {
          await LocalDbService.readReportsForExport(
            sheets[i].$1,
            excludeWithdraw: excludeWithdraw,
            isCancelled: cancelled,
            onPage: (page) {
              if (page.isEmpty) return;
              worker.send([
                _msgRows,
                i,
                [for (final r in page) excelExportRowValues(r)],
              ]);
              done += page.length;
              onProgress?.call(
                ExcelExportProgress(
                  ExcelExportPhase.reading,
                  done: done,
                  total: total < done ? done : total,
                ),
              );
            },
          );
        } on QueryCancelled {
          checkCancel();
          throw StateError('DB 연결이 닫혀 내보내기를 중단했습니다.');
        }
      }
      checkCancel();
      // 예전 코드처럼 감시 목록은 신고를 다 읽은 뒤 읽는다.
      final watchlist = await LocalDbService.getWatchlistNumbers();
      checkCancel();
      onProgress?.call(
        ExcelExportProgress(ExcelExportPhase.building, done: done, total: done),
      );
      worker.send([_msgFinish, watchlist.toList(growable: false)]);
      final bytes = await worker.result;
      checkCancel();
      return bytes;
    } on ExcelExportCancelled {
      rethrow;
    } catch (_) {
      // 작업자를 kill 해서 생긴 실패는 취소로 알린다.
      checkCancel();
      rethrow;
    } finally {
      worker.dispose();
    }
  }

  /// [directory] 에 `안전신문고_yyyyMMdd_HHmmss.xlsx` 를 저장한다. 취소·실패하면 파일을 남기지 않는다.
  static Future<File> exportToDirectory(
    Directory directory, {
    required bool excludeWithdraw,
    ExcelExportCancelToken? cancel,
    void Function(ExcelExportProgress progress)? onProgress,
    DateTime Function()? clock,
  }) async {
    final bytes = await buildWorkbookBytes(
      excludeWithdraw: excludeWithdraw,
      cancel: cancel,
      onProgress: onProgress,
    );
    if (cancel?.isCancelled == true) throw const ExcelExportCancelled();
    onProgress?.call(
      const ExcelExportProgress(ExcelExportPhase.saving, done: 0, total: 0),
    );
    final name = fileNameFor((clock ?? DateTime.now)());
    final target = File('${directory.path}/$name');
    final part = File('${target.path}.part');
    try {
      await part.writeAsBytes(bytes, flush: true);
      if (cancel?.isCancelled == true) throw const ExcelExportCancelled();
      return await part.rename(target.path);
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
  }
}

/// 사용자가 내보내기를 취소했다.
class ExcelExportCancelled implements Exception {
  const ExcelExportCancelled();
  @override
  String toString() => '내보내기를 취소했습니다.';
}

enum ExcelExportPhase { reading, building, saving }

class ExcelExportProgress {
  final ExcelExportPhase phase;
  final int done;
  final int total;
  const ExcelExportProgress(
    this.phase, {
    required this.done,
    required this.total,
  });

  /// 읽기 단계에서만 비율이 있다(만들기·저장은 한 번의 호출이라 비율을 모른다).
  double? get fraction => phase == ExcelExportPhase.reading && total > 0
      ? (done / total).clamp(0.0, 1.0)
      : null;
}

class ExcelExportCancelToken {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get _whenCancelled => _cancelled.future;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

// ── 행 값과 통합 문서(작업자 isolate 에서 실행) ─────────────────────────────

/// 신고 1건 → 작업자로 보내는 문자열 행. 첨부는 원문 그대로(시트에서 나눈다), 감시 여부는 작업자가 붙인다.
/// 순서: 예전 시트 열의 앞 20개 + 첨부사진 원문 + 첨부파일 원문 + 만족도조사여부 + 별점 + 별점사유.
List<String> excelExportRowValues(Report r) => [
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
  r.attachedPhotos,
  r.attachedFiles,
  r.pollStatus,
  r.rating?.toString() ?? '',
  r.ratingCause,
];

const _idxReportNumber = 2;
const _idxPhotos = 20;
const _idxFiles = 21;
const _idxPoll = 22;

List<String> _splitAttachments(String raw) => raw.isEmpty
    ? <String>[]
    : raw.split('\n').where((s) => s.trim().isNotEmpty).toList();

/// 예전 `_fillSheet` 과 같은 순서로 같은 셀을 쓴다. [rows] 는 이미 정렬된 행이다.
void _fillExportSheet(
  Excel excel,
  String sheetName,
  List<List<String>> rows,
  Set<String> watchlist,
) {
  final sheet = excel[sheetName];
  final photoLists = [for (final r in rows) _splitAttachments(r[_idxPhotos])];
  final fileLists = [for (final r in rows) _splitAttachments(r[_idxFiles])];
  final maxPhotos = photoLists.fold<int>(
    0,
    (m, l) => l.length > m ? l.length : m,
  );
  final maxFiles = fileLists.fold<int>(
    0,
    (m, l) => l.length > m ? l.length : m,
  );

  // 서버 export.py 컬럼 순서: original_cols + 지도 + 첨부사진N + 첨부파일N
  //                        + 만족도조사여부 + 별점 + 별점사유 + 감시목록
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

  for (var row = 0; row < rows.length; row++) {
    final r = rows[row];
    final photos = photoLists[row];
    final files = fileLists[row];
    final values = <String>[
      ...r.sublist(0, _idxPhotos),
      for (var i = 0; i < maxPhotos; i++) i < photos.length ? photos[i] : '',
      for (var i = 0; i < maxFiles; i++) i < files.length ? files[i] : '',
      ...r.sublist(_idxPoll),
      watchlist.contains(r[_idxReportNumber]) ? 'Y' : 'N',
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

/// 시트별 행(ID 오름차순으로 받은 그대로)을 예전과 같이 정렬해 통합 문서를 만든다.
List<int> _encodeWorkbook(
  List<List<List<String>>> sheetRows,
  Set<String> watchlist,
) {
  final excel = Excel.createExcel();
  for (var i = 0; i < ExcelExportService.sheets.length; i++) {
    final rows = sheetRows[i];
    // 예전: projected.sort((l, r) => _stringify(r['신고번호']).compareTo(_stringify(l['신고번호'])))
    rows.sort(
      (left, right) =>
          right[_idxReportNumber].compareTo(left[_idxReportNumber]),
    );
    _fillExportSheet(excel, ExcelExportService.sheets[i].$2, rows, watchlist);
  }
  // remove default sheet
  excel.delete('Sheet1');
  final bytes = excel.encode();
  if (bytes == null) throw Exception('Excel 인코딩 실패');
  return bytes;
}

const _msgRows = 0;
const _msgFinish = 1;

void _exportWorkerMain(SendPort replyTo) {
  final inbox = ReceivePort();
  replyTo.send(inbox.sendPort);
  final sheetRows = [
    for (var i = 0; i < ExcelExportService.sheets.length; i++) <List<String>>[],
  ];
  inbox.listen((message) {
    final m = message as List<Object?>;
    if (m[0] == _msgRows) {
      final rows = (m[2] as List).cast<List<String>>();
      sheetRows[m[1] as int].addAll(rows);
      return;
    }
    Object reply;
    try {
      final watchlist = (m[1] as List).cast<String>().toSet();
      final bytes = _encodeWorkbook(sheetRows, watchlist);
      reply = [
        true,
        TransferableTypedData.fromList([Uint8List.fromList(bytes)]),
      ];
    } catch (e) {
      reply = [false, e.toString()];
    }
    inbox.close();
    Isolate.exit(replyTo, reply);
  });
}

class _ExportWorker {
  final Isolate _isolate;
  final SendPort _port;
  final ReceivePort _replies;
  final Completer<Uint8List> _result;

  _ExportWorker._(this._isolate, this._port, this._replies, this._result);

  static Future<_ExportWorker> spawn() async {
    // 결과(Isolate.exit)와 종료 알림(onExit → null)을 같은 포트로 받아 순서를 보장한다.
    final replies = ReceivePort();
    final result = Completer<Uint8List>();
    // 취소(kill)로 아무도 기다리지 않는 사이에 실패해도 처리되지 않은 오류로 보고하지 않는다.
    result.future.ignore();
    final first = Completer<SendPort>();
    first.future.ignore();
    replies.listen((message) {
      if (message is SendPort) {
        if (!first.isCompleted) first.complete(message);
        return;
      }
      if (message == null) {
        // 정상 종료는 Isolate.exit 의 결과가 먼저 도착한다. 그 밖의 종료(kill·오류)는 실패다.
        if (!result.isCompleted) {
          result.completeError(StateError('내보내기 작업자가 중단되었습니다.'));
        }
        if (!first.isCompleted) {
          first.completeError(StateError('내보내기 작업자를 시작하지 못했습니다.'));
        }
        replies.close();
        return;
      }
      if (result.isCompleted) return;
      final m = message as List<Object?>;
      if (m[0] == true) {
        result.complete(
          (m[1] as TransferableTypedData).materialize().asUint8List(),
        );
      } else {
        result.completeError(Exception(m[1] as String));
      }
    });
    final isolate = await Isolate.spawn(
      _exportWorkerMain,
      replies.sendPort,
      onExit: replies.sendPort,
      debugName: 'excel-export',
    );
    final port = await first.future;
    return _ExportWorker._(isolate, port, replies, result);
  }

  Future<Uint8List> get result => _result.future;

  void send(Object? message) => _port.send(message);

  void kill() => _isolate.kill(priority: Isolate.immediate);

  void dispose() {
    if (!_result.isCompleted) {
      kill();
    } else {
      _replies.close();
    }
  }
}
