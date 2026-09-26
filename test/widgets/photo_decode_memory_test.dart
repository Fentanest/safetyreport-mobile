// 첨부 사진 디코딩 메모리 측정(수정 전 원본 해상도 vs 수정 후 ResizeImage) — Flutter 이미지 캐시의 실제 디코딩 바이트.
// 호스트 flutter_test 엔진에서 잰 값이다(Android 기기 측정 아님). 결과는 표준 출력에 남긴다.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';

Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF3366AA));
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<int> _decodedBytes(WidgetTester tester, ImageProvider provider) async {
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
  await tester.pumpWidget(MaterialApp(home: Image(image: provider)));
  await tester.runAsync(() => precacheImage(provider, tester.element(find.byType(Image))));
  await tester.pump();
  return cache.currentSizeBytes;
}

void main() {
  for (final (w, h) in [(4000, 3000), (1080, 20000)]) {
    testWidgets('decoded bytes for a ${w}x$h photo on a 411x891dp @2.625 phone', (tester) async {
      final bytes = (await tester.runAsync(() => _png(w, h)))!;
      final (dw, dh) = photoDecodeSize(logicalWidth: 411, screenHeight: 891, devicePixelRatio: 2.625);
      final before = await _decodedBytes(tester, MemoryImage(bytes));
      final after = await _decodedBytes(tester,
          ResizeImage(MemoryImage(Uint8List.fromList(bytes)), width: dw, height: dh, policy: ResizeImagePolicy.fit));
      // ignore: avoid_print
      print('MEASURE ${w}x$h before=$before after=$after');
      expect(before, w * h * 4);
      expect(after, lessThan(before));
    });
  }
}
