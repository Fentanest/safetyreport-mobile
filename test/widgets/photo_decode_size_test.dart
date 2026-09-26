// 첨부 사진 디코딩 크기(원본 해상도로 디코딩하지 않음 — Android 이미지 메모리, 요청서 §12-D).
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';

void main() {
  test('decode width follows the screen width in physical pixels; tall images are bounded', () {
    // 흔한 폰: 411×891dp, 2.625배 → 1079px 폭, 높이 상한 9356 → 8192
    expect(photoDecodeSize(logicalWidth: 411, screenHeight: 891, devicePixelRatio: 2.625), (1079, 8192));
    // 작은 화면: 360×640dp, 2배 → 720px, 높이 상한 5120
    expect(photoDecodeSize(logicalWidth: 360, screenHeight: 640, devicePixelRatio: 2), (720, 5120));
    // 태블릿 가로 폭이 커도 4096 을 넘지 않는다
    expect(photoDecodeSize(logicalWidth: 2000, screenHeight: 1200, devicePixelRatio: 3), (4096, 8192));
    // 비정상 비율은 1 로 본다
    expect(photoDecodeSize(logicalWidth: 400, screenHeight: 800, devicePixelRatio: 0), (400, 3200));
  });

  test('a 4000x3000 camera photo decodes to about the screen width (bytes = w*h*4)', () {
    final (w, h) = photoDecodeSize(logicalWidth: 411, screenHeight: 891, devicePixelRatio: 2.625);
    // ResizeImagePolicy.fit: 4000×3000 → 폭 1079 에 맞춰 1079×809 (높이 상한 안)
    final scale = [w / 4000, h / 3000].reduce((a, b) => a < b ? a : b);
    final decoded = (4000 * scale).round() * (3000 * scale).round() * 4;
    expect(decoded, lessThan(4000 * 3000 * 4 ~/ 10), reason: '원본 48MB → 약 3.5MB');
    // 1080×20000 세로 캡처: 높이 8192 에 맞춰 442×8192 (원본 86MB → 약 14MB)
    final tall = [w / 1080, h / 20000].reduce((a, b) => a < b ? a : b);
    expect((20000 * tall).round(), 8192);
  });
}
