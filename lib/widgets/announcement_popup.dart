import 'package:flutter/material.dart';

import '../announcements/announcement_model.dart';

/// 팝업에서 사용자가 고른 것.
enum AnnouncementChoice { primary, snooze, close }

/// 앱 공지 팝업 한 건(CLIENT-RULES 9절). 제목·본문은 평문 [Text] 로만 그린다(HTML·마크다운 해석 없음).
/// 버튼: 본 동작(허용된 것만) / "일주일 동안 보지 않기"(7일) 또는 "N일 동안 보지 않기"(0 이면 없음) / "닫기".
class AnnouncementPopup extends StatelessWidget {
  const AnnouncementPopup({super.key, required this.announcement});

  final AppAnnouncement announcement;

  static String snoozeLabel(int days) =>
      days == 7 ? '일주일 동안 보지 않기' : '$days일 동안 보지 않기';

  @override
  Widget build(BuildContext context) {
    final a = announcement;
    return AlertDialog(
      key: const Key('announcement_popup'),
      title: Text(a.title, key: const Key('announcement_title')),
      content: SingleChildScrollView(
        child: Text(a.body, key: const Key('announcement_body')),
      ),
      actionsOverflowDirection: VerticalDirection.down,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actions: [
        if (a.action != null)
          FilledButton(
            key: const Key('announcement_primary'),
            onPressed: () =>
                Navigator.of(context).pop(AnnouncementChoice.primary),
            child: Text(a.action!.label),
          ),
        if (a.snoozeDays > 0)
          TextButton(
            key: const Key('announcement_snooze'),
            onPressed: () =>
                Navigator.of(context).pop(AnnouncementChoice.snooze),
            child: Text(snoozeLabel(a.snoozeDays)),
          ),
        TextButton(
          key: const Key('announcement_close'),
          onPressed: () => Navigator.of(context).pop(AnnouncementChoice.close),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
