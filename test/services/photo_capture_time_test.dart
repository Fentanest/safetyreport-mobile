// 주정차 사진 EXIF 촬영 시각 — 서버와 같은 contracts/exif-vectors.json, 그리고 collect 규칙.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/photo_capture_time.dart';

Uint8List _hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

void main() {
  final doc =
      jsonDecode(File('contracts/exif-vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  for (final c in (doc['cases'] as List).cast<Map<String, dynamic>>()) {
    test('exif: ${c['name']}', () {
      expect(parseExifDateTime(_hex(c['hex'] as String)), c['expect']);
    });
  }

  test('collect: first/last/count, missing time ignored', () async {
    final times = {
      'https://a/1.jpg': '2026-09-22 13:20:53',
      'https://a/2.jpg': '2026-09-22 13:19:43',
      'https://a/3.jpg': null,
    };
    final r = await collectPhotoCapture(
      'https://a/1.jpg\nhttps://a/2.jpg\nhttps://a/3.jpg',
      fetch: (u) async => times[u],
    );
    expect(
      (r!.first, r.last, r.count),
      ('2026-09-22 13:19:43', '2026-09-22 13:20:53', 2),
    );
  });

  test(
    'collect: no urls → not attempted, network error → retry later, no exif → 0',
    () async {
      expect(await collectPhotoCapture('6개월 초과'), isNull);
      expect(
        await collectPhotoCapture(
          'https://a/1.jpg',
          fetch: (u) async => throw const SocketException('down'),
        ),
        isNull,
      );
      final none = await collectPhotoCapture(
        'https://a/1.jpg',
        fetch: (u) async => null,
      );
      expect((none!.first, none.count), (null, 0));
    },
  );
}
