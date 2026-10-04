import 'package:flutter/widgets.dart';

/// 본문 여백 + 시스템 바 여백(SQ-U26).
///
/// 앱은 가장자리까지 그린다(edge-to-edge, `main.dart`). 그래서 하단 내비가 없는 push 화면의
/// 마지막 항목은 3버튼 내비 아래로, 가로 모드 본문은 카메라 컷아웃·내비 아래로 들어갈 수 있다.
/// [base] 에 지금 [MediaQuery.paddingOf] 의 왼쪽·오른쪽·아래 값을 더한다.
/// 위쪽은 앱바가, 하단 탭 화면의 아래쪽은 하단 내비(Scaffold 가 아래 여백을 지운다)가 맡으므로
/// 같은 함수를 탭 본문에 써도 여백이 두 번 들어가지 않는다.
EdgeInsets srPagePadding(
  BuildContext context, [
  EdgeInsets base = EdgeInsets.zero,
]) {
  final inset = MediaQuery.paddingOf(context);
  return base +
      EdgeInsets.only(
        left: inset.left,
        right: inset.right,
        bottom: inset.bottom,
      );
}
