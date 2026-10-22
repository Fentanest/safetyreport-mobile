// 앱 공지 응답 검사(CLIENT-RULES 9절, contracts/app-announcements/response.schema.json).
// 서버도 같은 검사를 하지만 앱도 항목마다 다시 검사하고 틀린 항목은 버린다. 본문은 평문으로만 쓴다.
import 'package:flutter/foundation.dart';

enum AnnouncementActionKind { url, appAction }

@immutable
class AnnouncementAction {
  const AnnouncementAction.url(this.label, String this.url)
    : kind = AnnouncementActionKind.url,
      appAction = null;
  const AnnouncementAction.open(this.label, String this.appAction)
    : kind = AnnouncementActionKind.appAction,
      url = null;

  final AnnouncementActionKind kind;
  final String label;
  final String? url;
  final String? appAction;
}

@immutable
class AppAnnouncement {
  const AppAnnouncement({
    required this.id,
    required this.title,
    required this.body,
    required this.action,
    required this.snoozeDays,
    required this.priority,
  });

  final String id;
  final String title;
  final String body;

  /// 허용된 버튼만. 허용 목록 밖 링크·모르는 app_action 이면 null(버튼 숨김).
  final AnnouncementAction? action;
  final int snoozeDays;
  final int priority;

  /// 캐시에서 읽을 때도 [AnnouncementParser.item] 과 같은 검사를 거치도록 서버 모양으로 되돌린다.
  Map<String, Object?> toWire() => {
    'id': id,
    'title': title,
    'body': body,
    'primary_action': action == null
        ? null
        : {
            'label': action!.label,
            if (action!.url != null) 'url': action!.url,
            if (action!.appAction != null) 'app_action': action!.appAction,
          },
    'snooze_days': snoozeDays,
    'starts_at': '1970-01-01T00:00:00.000Z',
    'ends_at': null,
    'priority': priority,
  };
}

class AnnouncementParser {
  AnnouncementParser._();

  static const supportedAppActions = {'open_mode_switch'};
  static final _id = RegExp(r'^[a-z0-9][a-z0-9-]{2,63}$');
  static final _titleBad = RegExp(r'[\u0000-\u001f\u007f]');
  static final _bodyBad = RegExp(r'[\u0000-\u0009\u000b-\u001f\u007f]');
  static const _itemKeys = {
    'id',
    'title',
    'body',
    'primary_action',
    'snooze_days',
    'starts_at',
    'ends_at',
    'priority',
  };

  /// 응답 전체. 형식이 이상하면 null(아무것도 띄우지 않는다). 틀린 항목만 버리고 나머지는 우선순위 순서로.
  static List<AppAnnouncement>? response(Object? json) {
    if (json is! Map) return null;
    if (json.keys.toSet().difference({
      'protocol',
      'announcements',
      'server_time',
    }).isNotEmpty) {
      return null;
    }
    if (json['protocol'] != 1) return null;
    if (!_dateTime(json['server_time'])) return null;
    final list = json['announcements'];
    if (list is! List || list.length > 3) return null;
    final out = <AppAnnouncement>[];
    for (final raw in list) {
      final item = AnnouncementParser.item(raw);
      if (item != null && !out.any((o) => o.id == item.id)) out.add(item);
    }
    // 큰 priority 먼저(같으면 서버 순서 유지).
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
    indexed.sort((a, b) {
      final c = b.$2.priority.compareTo(a.$2.priority);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// 항목 하나. 틀리면 null.
  static AppAnnouncement? item(Object? raw) {
    if (raw is! Map) return null;
    if (raw.length != _itemKeys.length || !raw.keys.every(_itemKeys.contains)) {
      return null;
    }
    final id = raw['id'];
    final title = raw['title'];
    final body = raw['body'];
    final snooze = raw['snooze_days'];
    final priority = raw['priority'];
    if (id is! String || !_id.hasMatch(id)) return null;
    if (title is! String ||
        title.runes.isEmpty ||
        title.runes.length > 40 ||
        _titleBad.hasMatch(title)) {
      return null;
    }
    if (body is! String ||
        body.runes.isEmpty ||
        body.runes.length > 600 ||
        _bodyBad.hasMatch(body)) {
      return null;
    }
    if (snooze is! int || snooze < 0 || snooze > 365) return null;
    if (priority is! int) return null;
    if (!_dateTime(raw['starts_at'])) return null;
    if (raw['ends_at'] != null && !_dateTime(raw['ends_at'])) return null;

    final action = raw['primary_action'];
    AnnouncementAction? resolved;
    if (action != null) {
      if (action is! Map) return null;
      final label = action['label'];
      if (label is! String || label.runes.isEmpty || label.runes.length > 20) {
        return null;
      }
      if (_titleBad.hasMatch(label)) return null;
      final keys = action.keys.toSet();
      if (keys.length == 2 && keys.containsAll({'label', 'url'})) {
        final url = action['url'];
        if (url is! String || url.length > 500) return null;
        if (linkAllowed(url)) resolved = AnnouncementAction.url(label, url);
      } else if (keys.length == 2 &&
          keys.containsAll({'label', 'app_action'})) {
        final app = action['app_action'];
        if (app is! String) return null;
        // 모르는 값은 항목은 두고 버튼만 숨긴다(9절).
        if (supportedAppActions.contains(app)) {
          resolved = AnnouncementAction.open(label, app);
        }
      } else {
        return null;
      }
    }
    return AppAnnouncement(
      id: id,
      title: title,
      body: body,
      action: resolved,
      snoozeDays: snooze,
      priority: priority,
    );
  }

  static bool _dateTime(Object? v) {
    if (v is! String || v.length > 40) return false;
    if (!RegExp(
      r'^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$',
    ).hasMatch(v)) {
      return false;
    }
    return DateTime.tryParse(v) != null;
  }

  /// `contracts/app-announcements/vectors/links.json` 규칙. 서버(SQL `private.app_announcement_url_allowed`,
  /// Edge `announcementUrlAllowed`)와 **같은 정규식**을 쓴다 — 벡터 밖 경우(쿼리·조각·특수문자·한글 경로·대문자 호스트)도
  /// 같은 결과가 나오게. 세 형태 모두 ASCII 문자만 허용하므로 공백·제어문자·`<>"\`·한글은 저절로 거부된다.
  static bool linkAllowed(String url) {
    if (url.isEmpty || url.runes.length > 500) return false;
    if (RegExp(r'[\s\u0000-\u001f\u007f<>"\\]').hasMatch(url)) return false;
    return _playLink.hasMatch(url) ||
        _githubLink.hasMatch(url) ||
        _worklazyLink.hasMatch(url);
  }

  static final _playLink = RegExp(
    r'^https://play\.google\.com/store/apps/details\?id=com\.fentanest\.mysafetyreport(&[A-Za-z0-9._~=%-]+)*$',
  );
  static final _githubLink = RegExp(
    r'^https://github\.com/Fentanest/[A-Za-z0-9._~/%?=&#+-]*$',
  );
  static final _worklazyLink = RegExp(
    r'^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*worklazy\.net(/[A-Za-z0-9._~/%?=&#+-]*)?$',
  );
}
