import 'package:flutter/widgets.dart';

/// 다이얼로그·바텀시트가 builder 밖에서 만든 컨트롤러를 그 route 가 완전히 사라질 때 해제한다(SQ-B14).
///
/// `await showDialog(...)` 직후에 해제하면 닫힘 애니메이션 동안 아직 그려지는 TextField 가 해제된 컨트롤러를 쓴다.
/// 이 위젯은 route 의 내용 맨 위에 두며, Flutter 는 하위 위젯을 먼저 unmount 하므로
/// [onDispose] 는 그 안의 TextField 들이 사라진 뒤에 불린다.
class DisposeOnUnmount extends StatefulWidget {
  const DisposeOnUnmount({
    super.key,
    required this.onDispose,
    required this.child,
  });

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<DisposeOnUnmount> createState() => _DisposeOnUnmountState();
}

class _DisposeOnUnmountState extends State<DisposeOnUnmount> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
