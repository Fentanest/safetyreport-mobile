import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/utils/format.dart';

void main() {
  group('formatNumber', () {
    test('세 자리마다 쉼표를 찍는다', () {
      expect(formatNumber(0), '0');
      expect(formatNumber(7), '7');
      expect(formatNumber(999), '999');
      expect(formatNumber(1000), '1,000');
      expect(formatNumber(12345), '12,345');
      expect(formatNumber(123456), '123,456');
      expect(formatNumber(1234567), '1,234,567');
      expect(formatNumber(950520000), '950,520,000');
    });

    test('음수는 부호 뒤 숫자에만 쉼표를 찍는다', () {
      expect(formatNumber(-5), '-5');
      expect(formatNumber(-1234), '-1,234');
      expect(formatNumber(-1234567), '-1,234,567');
    });

    test('실수는 소수점 아래를 버린다(표시 전용)', () {
      expect(formatNumber(1234.9), '1,234');
    });
  });

  test('formatCount 는 쉼표 + 건', () {
    expect(formatCount(0), '0건');
    expect(formatCount(100), '100건');
    expect(formatCount(12345), '12,345건');
  });

  test('formatWon 은 만 단위 표기 없이 전체 쉼표 + 원', () {
    expect(formatWon(0), '0원');
    expect(formatWon(9500), '9,500원');
    expect(formatWon(95000), '95,000원');
    expect(formatWon(120000), '120,000원');
    expect(formatWon(950520000), '950,520,000원');
    expect(formatWon(95000), isNot(contains('만')));
  });
}
