// 주정차 신고 사진의 촬영 시각(EXIF). 서버 services/photo_capture_time.py 와 같은 규칙 —
// 같은 입력이면 같은 결과(contracts/exif-vectors.json 으로 양쪽 테스트).
//
// 안전신문고 앱 카메라 사진은 EXIF DateTimeOriginal 에 촬영 시각을 남긴다. 첨부 URL 은 약 6개월 뒤 만료되므로
// 크롤링·동기화 때 사진 앞부분(128KB)만 받아 읽는다. 추정 과태료(2시간 초과·밤샘주차 판정)에 쓰인다.
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const photoCaptureMaxBytes = 128 * 1024;
const _timeout = Duration(seconds: 15);
const _tagDateTime = 0x0132;
const _tagExifIfd = 0x8769;
const _tagDateTimeOriginal = 0x9003;

/// 첨부 사진들의 첫/끝 촬영 시각과 읽은 장수.
class PhotoCapture {
  const PhotoCapture({this.first, this.last, required this.count});
  final String? first;
  final String? last;
  final int count;
}

bool isParkingReport(String? category, String? entryValue) =>
    category == 'parking' || (entryValue ?? '').contains('불법주정차신고');

List<String> photoUrls(String? attachedPhotos) => (attachedPhotos ?? '')
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.startsWith('http'))
    .toList();

int _u16(ByteData d, int o, Endian e) => d.getUint16(o, e);
int _u32(ByteData d, int o, Endian e) => d.getUint32(o, e);

String? _readAsciiTag(
  Uint8List tiff,
  Endian endian,
  int ifdOffset,
  int wanted,
) {
  final data = ByteData.sublistView(tiff);
  if (ifdOffset + 2 > tiff.length) return null;
  final count = _u16(data, ifdOffset, endian);
  for (var i = 0; i < count; i++) {
    final entry = ifdOffset + 2 + i * 12;
    if (entry + 12 > tiff.length) return null;
    final tag = _u16(data, entry, endian);
    final typ = _u16(data, entry + 2, endian);
    final n = _u32(data, entry + 4, endian);
    final value = _u32(data, entry + 8, endian);
    if (tag != wanted) continue;
    if (tag == _tagExifIfd) return value.toString();
    if (typ != 2 || n == 0) return null;
    final start = n <= 4 ? entry + 8 : value;
    if (start >= tiff.length) return null;
    final end = (start + n) > tiff.length ? tiff.length : start + n;
    final raw = tiff.sublist(start, end);
    final zero = raw.indexOf(0);
    final text = String.fromCharCodes(
      zero >= 0 ? raw.sublist(0, zero) : raw,
    ).trim();
    return text.isEmpty ? null : text;
  }
  return null;
}

String? _parseTiffDateTime(Uint8List tiff) {
  if (tiff.length < 8) return null;
  final Endian endian;
  if (tiff[0] == 0x49 && tiff[1] == 0x49) {
    endian = Endian.little;
  } else if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
    endian = Endian.big;
  } else {
    return null;
  }
  final ifd0 = _u32(ByteData.sublistView(tiff), 4, endian);
  String? value;
  final exifIfd = _readAsciiTag(tiff, endian, ifd0, _tagExifIfd);
  if (exifIfd != null) {
    value = _readAsciiTag(
      tiff,
      endian,
      int.parse(exifIfd),
      _tagDateTimeOriginal,
    );
  }
  value ??= _readAsciiTag(tiff, endian, ifd0, _tagDateTime);
  if (value == null || value.isEmpty) return null;
  final m = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(value);
  if (m == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  // 날짜로 성립하지 않으면(13월, 99시 등) 버린다 — 서버 strptime 과 같음
  final dt = DateTime(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if (dt.year != parts[0] ||
      dt.month != parts[1] ||
      dt.day != parts[2] ||
      dt.hour != parts[3] ||
      dt.minute != parts[4] ||
      dt.second != parts[5]) {
    return null;
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${parts[0].toString().padLeft(4, '0')}-${two(parts[1])}-${two(parts[2])} '
      '${two(parts[3])}:${two(parts[4])}:${two(parts[5])}';
}

/// JPEG 앞부분에서 촬영 시각을 'YYYY-MM-DD HH:MM:SS' 로. 없거나 잘렸으면 null.
String? parseExifDateTime(Uint8List data) {
  if (data.length < 4 || data[0] != 0xFF || data[1] != 0xD8) return null;
  var pos = 2;
  while (pos + 4 <= data.length) {
    if (data[pos] != 0xFF) return null;
    final marker = data[pos + 1];
    if (marker == 0xD9 || marker == 0xDA) return null; // EOI / SOS: 메타데이터 구간 끝
    final length = (data[pos + 2] << 8) | data[pos + 3];
    final segEnd = (pos + 2 + length) > data.length
        ? data.length
        : pos + 2 + length;
    final segment = data.sublist(pos + 4 < segEnd ? pos + 4 : segEnd, segEnd);
    if (marker == 0xE1 &&
        segment.length >= 6 &&
        String.fromCharCodes(segment.sublist(0, 4)) == 'Exif' &&
        segment[4] == 0 &&
        segment[5] == 0) {
      return _parseTiffDateTime(segment.sublist(6));
    }
    pos += 2 + length;
  }
  return null;
}

/// 사진 앞부분만 받아 촬영 시각을 읽는다. 원본 서버가 Range 를 지원하지 않아 스트리밍하다 끊는다.
/// 네트워크·HTTP 오류는 예외로 올린다(호출하는 쪽이 다음에 다시 시도).
Future<String?> fetchCaptureTime(String url, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = 'Mozilla/5.0';
    final res = await c.send(req).timeout(_timeout);
    if (res.statusCode != 200) {
      throw http.ClientException('HTTP ${res.statusCode}', Uri.parse(url));
    }
    final buf = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(_timeout)) {
      buf.add(chunk);
      if (buf.length >= photoCaptureMaxBytes) break;
    }
    return parseExifDateTime(buf.takeBytes());
  } finally {
    if (client == null) c.close();
  }
}

/// 서버 collect() 와 같은 규칙. URL 이 없으면 null(시도 안 함), 네트워크 오류가 하나라도 나면 null(다음에 다시),
/// 모두 받았지만 촬영 시각이 없으면 count 0(다시 시도하지 않음).
Future<PhotoCapture?> collectPhotoCapture(
  String? attachedPhotos, {
  Future<String?> Function(String url)? fetch,
}) async {
  final urls = photoUrls(attachedPhotos);
  if (urls.isEmpty) return null;
  final get = fetch ?? fetchCaptureTime;
  final times = <String>[];
  for (final url in urls) {
    try {
      final v = await get(url);
      if (v != null && v.isNotEmpty) times.add(v);
    } catch (_) {
      return null;
    }
  }
  times.sort();
  return PhotoCapture(
    first: times.isEmpty ? null : times.first,
    last: times.isEmpty ? null : times.last,
    count: times.length,
  );
}
