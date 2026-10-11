// 지터(±20%)를 끈 고정 Random — CloudAvailability 에 지터가 생기기 전 시험의 정확한 쿨다운 값을
// 그대로 유지하면서(강도를 낮추지 않고), 새 난수원을 결정적으로 만든다.
// nextDouble()==0.5 → 지터 factor == 1.0(무지터). 지터 자체의 폭(±20%)은
// cloud_availability_test.dart 에서 0.0/1.0 을 주입해 따로 검증한다.
import 'dart:math';

class FixedRandom implements Random {
  const FixedRandom([this.value = 0.5]);
  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (value * max).floor().clamp(0, max - 1);

  @override
  bool nextBool() => value >= 0.5;
}
