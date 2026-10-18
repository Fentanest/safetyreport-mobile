import 'package:flutter_test/flutter_test.dart';
import '../support/stats_identity_widget.dart';

void main() {
  testWidgets('분류별 기관·담당자 카드 1건 = 목록 1건 (동명 최신 200건 제외)',
      (tester) => checkIdentityCards(tester, 'traffic'));
}
