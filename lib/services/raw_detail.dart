import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_storage_paths.dart';

// 상세 원본 정규 직렬화(2026-10-17 명세 1-1, 서버 core/utils/raw_detail.py 와 같은 규칙).
// 응답 envelope(JSON 객체) 전체를 저장한다. `result` 가 객체일 때만 그 안의 신고자 키 5개
// (C_NAME·C_EMAIL·C_PHONE·C_PHONE2·C_ID)를 지운다. 다른 위치의 같은 이름은 건드리지 않는다.
// 키 순서는 응답 순서를 유지한다.
//
// 직렬화: UTF-8, 비ASCII 그대로, 공백 없는 구분자(Dart `jsonEncode` —
// Python `json.dumps(obj, ensure_ascii=False, separators=(",", ":"))` 와 같은 바이트).
// DB 저장값은 그 바이트를 zlib(RFC 1950, 레벨 6)으로 압축한 BLOB 이다.
// 교환·백업은 저장된 BLOB 바이트를 그대로 옮긴다(재압축 금지) — 서버와 바이트가 달라도 된다.
// 읽을 때는 zlib 해제 뒤 sha256 이 맞는지 확인한다. 안 맞으면 그 행은 "손상"으로 보고
// 원본 보기·재파싱에서 쓰지 않는다(조용히 버리지 않고 로그).

/// `result` 안에서 지우는 신고자 키 5개(서버 REPORTER_KEYS·계약 벡터 reporter_keys 와 같은 순서).
const rawDetailReporterKeys = <String>[
  'C_NAME',
  'C_EMAIL',
  'C_PHONE',
  'C_PHONE2',
  'C_ID',
];

/// [LocalDbService.upsertReport] 에 함께 저장하는 상세 원본 한 건(신고 행과 같은 트랜잭션).
class RawDetailUpsert {
  final Uint8List zlib;
  final String sha256;
  final int size;
  final String fetchedAt;
  final String source;

  const RawDetailUpsert({
    required this.zlib,
    required this.sha256,
    required this.size,
    required this.fetchedAt,
    required this.source,
  });
}

/// 정규 직렬화 결과: 신고자 키를 뺀 사본, 그 UTF-8 바이트, 바이트의 sha256(hex 소문자).
({
  Map<String, dynamic> sanitized,
  Uint8List canonical,
  String sha256,
}) prepareRawDetail(Map<String, dynamic> envelope) {
  final sanitized = _sanitizeEnvelope(envelope);
  final canonical = Uint8List.fromList(utf8.encode(jsonEncode(sanitized)));
  return (sanitized: sanitized, canonical: canonical, sha256: sha256Hex(canonical));
}

Map<String, dynamic> _sanitizeEnvelope(Map<String, dynamic> envelope) {
  final copy = Map<String, dynamic>.from(envelope);
  final result = copy['result'];
  if (result is Map<String, dynamic>) {
    copy['result'] = {
      for (final entry in result.entries)
        if (!rawDetailReporterKeys.contains(entry.key)) entry.key: entry.value,
    };
  }
  return copy;
}

/// 바이트의 sha256(hex 소문자, 서버 sha256_hex 와 같음).
String sha256Hex(List<int> payload) => sha256.convert(payload).toString();

/// zlib(RFC 1950) 레벨 6 압축(서버 `zlib.compress(b, 6)` 과 같은 설정).
Uint8List compressRawDetail(List<int> canonical) =>
    Uint8List.fromList(_zlibLevel6.encode(canonical));

final _zlibLevel6 = ZLibCodec(level: 6);
final _zlibDefault = ZLibCodec();

/// zlib 해제 + sha256 대조. 해제 실패·불일치면 손상(서버 verify 의 ValueError 와 같은 뜻)으로 던진다.
Uint8List decompressAndVerifyRawDetail(Uint8List blob, String expectedSha256) {
  List<int> raw;
  try {
    raw = _zlibDefault.decode(blob);
  } catch (e) {
    throw StateError('상세 원본 zlib 해제 실패(손상): $e');
  }
  final actual = sha256Hex(raw);
  if (actual != expectedSha256) {
    throw StateError('상세 원본 sha256 불일치(손상)');
  }
  return Uint8List.fromList(raw);
}

/// 받은 시각(UTC ISO8601, 밀리초, Z — 서버 utc_now_fetched_at 과 같은 형식).
String formatRawFetchedAt(DateTime now) {
  final utc = now.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}.${three(utc.millisecond)}Z';
}

/// 원본 파일 이름에 쓸 수 있는 신고 ID(서버 `is_safe_report_id` 와 같은 규칙).
/// 영숫자·`_`·`-`만, 1~64자. 슬래시·역슬래시·점·공백·빈 값 등은 쓰지 않는다.
final _safeReportId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// 원본 파일 이름에 그대로 넣어도 되는 신고 ID 인지. 아니면 false.
bool isSafeReportId(String reportId) => _safeReportId.hasMatch(reportId);

/// `directory/<ID>.json` 정규화 경로(서버 `raw_file_path` 와 같은 규칙).
/// ID 가 파일 이름 규칙에 안 맞거나 정규화한 최종 경로가 `directory` 를
/// 벗어나면 null(쓰지 않고 호출자가 진단만 기록한다).
String? rawFilePath(String reportId, Directory directory) {
  if (!isSafeReportId(reportId)) return null;
  final base = p.normalize(directory.absolute.path);
  final path = p.normalize(p.join(base, '$reportId.json'));
  if (p.dirname(path) != base) return null;
  return path;
}

/// 원본 파일(사람이 보는 사본): 신고자 키를 뺀 객체를 들여쓰기 2칸 UTF-8 JSON(비ASCII 그대로)으로 쓴다.
/// 신고당 최신 1개, 받을 때마다 덮어쓴다(임시 파일 → rename).
/// 기본 위치는 `Documents/mysafetyreport/raw_details/<ID>.json`([AppStoragePaths.subDir]).
/// [dir] 을 지정하면 그곳에 쓴다(시험용).
/// ID 가 파일 이름 규칙에 안 맞거나 최종 경로가 디렉터리를 벗어나면 쓰지 않고
/// 진단 기록만 남기고 null 을 돌려준다(서버 `write_raw_file` 과 같음). 쓴 경로면 그 경로.
/// 파일 쓰기 실패는 예외를 던진다(호출자가 DB 저장을 유지하고 로그만 남긴다).
Future<String?> writeRawDetailFile(
  String reportId,
  Map<String, dynamic> sanitized, {
  Directory? dir,
}) async {
  final targetDir = dir ?? AppStoragePaths.subDir('raw_details');
  final targetPath = rawFilePath(reportId, targetDir);
  if (targetPath == null) {
    debugPrint('원본 파일 쓰기 건너뜀 — 안전하지 않은 ID: $reportId');
    return null;
  }
  final tmp = File('$targetPath.tmp');
  final target = File(targetPath);
  const encoder = JsonEncoder.withIndent('  ');
  await tmp.writeAsString(encoder.convert(sanitized), encoding: utf8);
  await tmp.rename(target.path);
  return targetPath;
}
