import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../community/community_store.dart' show newUuidV4;

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
  static const queue = 'inbox.queue.';
  static int _seq = 0;
  static final _claimOwner = newUuidV4();
  static final _migrated = <String>{};
  static final _claimed = <String, Set<String>>{};
  @visibleForTesting
  static bool useNativeBridgeForTest = false;
  static bool get _useNative => Platform.isAndroid || useNativeBridgeForTest;
  static const _channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  static Future<void> synchronize(
    SharedPreferences prefs,
    String prefix,
  ) async {
    if (prefix == history || !_useNative) return;
    try {
      final mirrors = prefs
          .getKeys()
          .where((k) => k.startsWith('${prefix}native.'))
          .toList();
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'processingInboxRead',
        {'prefix': prefix, 'mirrors': mirrors, 'owner': _claimOwner},
      );
      if (result == null) throw StateError('processing inbox unavailable');
      _migrated.removeWhere((k) => k.startsWith(prefix));
      _migrated.addAll((result['migrated'] as List? ?? []).cast<String>());
      _claimed[prefix] = (result['pending'] as List)
          .map((raw) => (raw as Map)['key'] as String)
          .toSet();
      for (final key in (result['acknowledged'] as List).cast<String>()) {
        if (!await prefs.remove(key)) {
          throw StateError('processing mirror removal failed');
        }
      }
      for (final raw in result['pending'] as List) {
        final entry = raw as Map;
        if (!await prefs.setString(
          entry['key'] as String,
          entry['value'] as String,
        )) {
          throw StateError('processing mirror failed');
        }
      }
      if ((result['blockedScope'] as int? ?? 0) > 0) {
        throw StateError('이전 계정 또는 설정의 처리 의도를 보존했습니다. 소유권 확인이 필요합니다.');
      }
      if ((result['blockedLegacy'] as int? ?? 0) > 0) {
        throw StateError('기존 처리 큐의 소유권 확인이 필요합니다. 자료는 보존했습니다.');
      }
    } on MissingPluginException {
      if (Platform.isAndroid) rethrow;
    }
  }

  static Future<bool> _putNative(String prefix, String value) async {
    if (prefix == history || !_useNative) return false;
    try {
      final key = await _channel.invokeMethod<String>('processingInboxPut', {
        'prefix': prefix,
        'value': value,
      });
      if (key == null || key.isEmpty) {
        throw StateError('processing event not persisted');
      }
      return true;
    } on MissingPluginException {
      // A headless engine without the Activity bridge retains a unique legacy
      // key; the next bridge migration copies it durably before removing it.
      return false;
    }
  }

  static bool isReadableKey(String key, String prefix) =>
      !_useNative ||
      (!_migrated.contains(key) &&
          (!key.startsWith('${prefix}native.') ||
              (_claimed[prefix]?.contains(key) ?? false)));

  /// [prefix] 아래 키를 오래된 순으로 읽는다. 각 값은 JSON 배열(깨진 값은 빈 배열).
  static List<({String key, List<Map<String, dynamic>> items})> read(
    SharedPreferences prefs,
    String prefix,
  ) {
    final keys =
        prefs
            .getKeys()
            .where((k) => k.startsWith(prefix) && isReadableKey(k, prefix))
            .toList()
          ..sort();
    return [
      for (final k in keys)
        (key: k, items: _decode(prefs.get(k), strict: prefix != history)),
    ];
  }

  static Future<void> remove(
    SharedPreferences prefs,
    Iterable<String> keys,
  ) async {
    final list = keys.toList();
    final native = list
        .where(
          (k) =>
              k.startsWith('${queue}native.') ||
              k.startsWith('${pending}native.'),
        )
        .toList();
    if (native.isNotEmpty && _useNative) {
      try {
        final ack = await _channel.invokeMethod<bool>('processingInboxAck', {
          'keys': native,
          'owner': _claimOwner,
        });
        if (ack != true) throw StateError('processing ACK unconfirmed');
      } on MissingPluginException {
        if (Platform.isAndroid) rethrow;
      }
    }
    for (final k in list) {
      if (!await prefs.remove(k)) throw StateError('inbox removal failed');
    }
  }

  /// 앱도 공유 키 대신 새 키에 넣는다(읽고-고쳐-쓰기 없음).
  static Future<void> put(
    SharedPreferences prefs,
    String prefix,
    List<Map<String, dynamic>> items,
  ) async {
    final value = jsonEncode(items);
    if (!await _putNative(prefix, value) &&
        !await prefs.setString(_newKey(prefix), value)) {
      throw StateError('inbox persistence failed');
    }
  }

  /// 값 하나(문자열)를 새 키에 넣는다. Standalone 감지 큐용.
  static Future<void> putString(
    SharedPreferences prefs,
    String prefix,
    String value,
  ) async {
    if (!await _putNative(prefix, value) &&
        !await prefs.setString(_newKey(prefix), value)) {
      throw StateError('inbox persistence failed');
    }
  }

  static String _newKey(String prefix) {
    final ms = DateTime.now().millisecondsSinceEpoch.toString().padLeft(
      15,
      '0',
    );
    final seq = (++_seq).toString().padLeft(6, '0');
    return '$prefix${ms}_d${seq}_${newUuidV4()}';
  }

  static List<Map<String, dynamic>> _decode(
    Object? raw, {
    bool strict = false,
  }) {
    if (raw is! String || raw.isEmpty) {
      if (strict) {
        throw const FormatException('processing inbox value malformed');
      }
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || (strict && decoded.any((e) => e is! Map))) {
        throw const FormatException('processing inbox payload malformed');
      }
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      if (strict) rethrow;
      return const [];
    }
  }
}
