import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 백그라운드 서비스(Kotlin WsService)와 앱이 주고받는 설정 수신함 (M-29/M-31, 저장 계층 재설계 R6).
///
/// 예전엔 두 쪽이 같은 키(알림 기록·대기 변경)를 읽고-고쳐-써서, 거의 동시에 쓰면 한쪽 쓰기가 사라졌다.
/// 이제 넣는 쪽은 항목마다 고유한 새 키(`<prefix><epoch ms 15자리>_<순번>`)에만 쓰고,
/// 합치기와 지우기는 앱이 한다 — 합친 키만 이름으로 지우므로 그 사이 새로 들어온 키는 남는다.
/// 키 이름은 WsService.kt 의 INBOX_* 와 같아야 한다(거기엔 "flutter." 접두어가 붙음).
class PrefsInbox {
  PrefsInbox._();

  static const history = 'inbox.history.';
  static const pending = 'inbox.pending.';
  static int _seq = 0;

  /// [prefix] 아래 키를 오래된 순으로 읽는다. 각 값은 JSON 배열(깨진 값은 빈 배열).
  static List<({String key, List<Map<String, dynamic>> items})> read(
    SharedPreferences prefs,
    String prefix,
  ) {
    final keys = prefs.getKeys().where((k) => k.startsWith(prefix)).toList()
      ..sort();
    return [for (final k in keys) (key: k, items: _decode(prefs.get(k)))];
  }

  static Future<void> remove(
    SharedPreferences prefs,
    Iterable<String> keys,
  ) async {
    for (final k in keys) {
      await prefs.remove(k);
    }
  }

  /// 앱도 공유 키 대신 새 키에 넣는다(읽고-고쳐-쓰기 없음).
  static Future<void> put(
    SharedPreferences prefs,
    String prefix,
    List<Map<String, dynamic>> items,
  ) async {
    final ms = DateTime.now().millisecondsSinceEpoch.toString().padLeft(
      15,
      '0',
    );
    final seq = (++_seq).toString().padLeft(6, '0');
    await prefs.setString('$prefix${ms}_d$seq', jsonEncode(items));
  }

  static List<Map<String, dynamic>> _decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
