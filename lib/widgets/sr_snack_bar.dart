import 'package:flutter/material.dart';

import '../theme/sr_colors.dart';

/// SnackBar 종류. [info] 는 테마 기본(inverseSurface 배경), 나머지는 의미색 채움 + 흰 글자.
enum SrSnackKind { info, success, warning, error }

/// 앱 공통 SnackBar(SQ-U23). 오류 SnackBar 가 `srSnackError` 와 `colorScheme.error` 로 갈리고,
/// 다크에서 채움 배경 위에 어두운 기본 글자(onInverseSurface)가 올라가던 문제를 한 곳에서 맞춘다.
/// 채움 배경(성공 5.0:1 · 경고 5.0:1 · 오류 6.5:1)은 두 테마 같은 값이고 글자는 늘 흰색이다.
SnackBar srSnackBar(
  String message, {
  SrSnackKind kind = SrSnackKind.info,
  Duration? duration,
  SnackBarAction? action,
  IconData? icon,
}) {
  final background = switch (kind) {
    SrSnackKind.info => null,
    SrSnackKind.success => srSnackSuccess,
    SrSnackKind.warning => srSnackWarning,
    SrSnackKind.error => srSnackError,
  };
  final foreground = background == null ? null : Colors.white;
  final text = Text(message, style: TextStyle(color: foreground));
  return SnackBar(
    content: icon == null
        ? text
        : _IconRow(icon: icon, color: foreground, child: text),
    backgroundColor: background,
    duration: duration ?? const Duration(milliseconds: 4000),
    action: action == null || foreground == null
        ? action
        : SnackBarAction(
            label: action.label,
            onPressed: action.onPressed,
            textColor: foreground,
          ),
  );
}

/// [context] 의 ScaffoldMessenger 에 [srSnackBar] 를 띄운다. messenger 가 없으면 아무것도 하지 않는다.
/// [hideCurrent] 가 참이면 떠 있는 SnackBar 를 먼저 닫는다.
void showSrSnack(
  BuildContext context,
  String message, {
  SrSnackKind kind = SrSnackKind.info,
  Duration? duration,
  SnackBarAction? action,
  IconData? icon,
  bool hideCurrent = false,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  showSrSnackOn(
    messenger,
    message,
    kind: kind,
    duration: duration,
    action: action,
    icon: icon,
    hideCurrent: hideCurrent,
  );
}

/// await 전에 잡아 둔 [messenger] 로 띄울 때.
void showSrSnackOn(
  ScaffoldMessengerState messenger,
  String message, {
  SrSnackKind kind = SrSnackKind.info,
  Duration? duration,
  SnackBarAction? action,
  IconData? icon,
  bool hideCurrent = false,
}) {
  if (hideCurrent) messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    srSnackBar(
      message,
      kind: kind,
      duration: duration,
      action: action,
      icon: icon,
    ),
  );
}

class _IconRow extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final Widget child;

  const _IconRow({required this.icon, required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    // 기본(info) SnackBar 는 inverseSurface 배경이라 아이콘도 onInverseSurface 로 맞춘다.
    final fg = color ?? Theme.of(context).colorScheme.onInverseSurface;
    return Row(
      children: [
        Icon(icon, size: 16, color: fg),
        const SizedBox(width: 8),
        Flexible(child: child),
      ],
    );
  }
}
