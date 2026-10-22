import 'package:flutter/material.dart';

import '../community/notify/user_action_notifier.dart';

/// 화면 상단의 사용자 조치 안내(CLIENT-RULES 8절). 알림 권한이 없어도 같은 문장을 보여 준다.
///
/// B 가 메인 화면 상단에 붙인다. [onLogin]·[onRetry] 는 각각 공식 로그인 화면 열기, 올리지 못한 신고 다시 시도.
/// 해당 콜백이 null 이면 그 버튼은 그리지 않는다. 한 번에 가장 급한 안내 한 건만 보인다.
/// `update_required` 는 전체 화면 잠금이 맡으므로 여기서는 그리지 않는다.
class UserActionBanner extends StatefulWidget {
  const UserActionBanner({super.key, this.onLogin, this.onRetry});

  final VoidCallback? onLogin;
  final VoidCallback? onRetry;

  @override
  State<UserActionBanner> createState() => _UserActionBannerState();
}

class _UserActionBannerState extends State<UserActionBanner> {
  @override
  void initState() {
    super.initState();
    UserActionNotifier.load();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<UserActionItem>>(
      valueListenable: UserActionNotifier.items,
      builder: (context, list, _) {
        final shown = list
            .where((i) => i.reason != UserActionNotifier.reasonUpdateRequired)
            .toList();
        if (shown.isEmpty) return const SizedBox.shrink();
        final item = shown.first;
        final scheme = Theme.of(context).colorScheme;
        final (text, label, callback) = switch (item.reason) {
          UserActionNotifier.reasonOfficialLogin => (
            item.notificationText,
            '로그인',
            widget.onLogin,
          ),
          UserActionNotifier.reasonStaleHolds => (
            item.notificationText,
            '다시 시도',
            widget.onRetry,
          ),
          UserActionNotifier.reasonOptimizeBlocked => (
            '앱을 열어 두면 신고 정리를 마치고 공유를 이어 갑니다.',
            '',
            null,
          ),
          _ => ('', '', null),
        };
        if (text.isEmpty) return const SizedBox.shrink();
        return Material(
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    key: const Key('user_action_banner_text'),
                    style: TextStyle(color: scheme.onSecondaryContainer),
                  ),
                ),
                if (callback != null && label.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('user_action_banner_button'),
                    onPressed: callback,
                    child: Text(label),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
