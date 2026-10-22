// 필수 버전과 앱 잠금 — CLIENT-RULES 6절(2-10).
//
// 먹통 방지가 먼저다: 정상 status 응답이 "요구 버전 > 내 버전"을 **명시했을 때만** 잠그고, 해제도 정상 응답에서만 한다.
// 시간 초과·네트워크·5xx·429·형식 이상·`client_requirement` 키 없음·버전 해석 불가는 마지막 판정을 그대로 둔다.
// 판정은 SharedPreferences(`community_update_requirement_v1`)에 두어 재시작·백그라운드 isolate 도 같은 값을 본다.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_version.dart';

/// `contracts/community-ingest-v2/version-vectors.json` 규칙:
/// `[v]N[.N[.N[.N]]][+build]`, N 은 1~6자리, 빠진 자리 0, 앞뒤 ASCII 공백만 잘라 40자 이하. 그 밖은 해석 불가(null).
final _versionPattern = RegExp(
  r'^v?([0-9]{1,6})(?:\.([0-9]{1,6}))?(?:\.([0-9]{1,6}))?(?:\.([0-9]{1,6}))?(?:\+[0-9A-Za-z.-]{1,32})?$',
);

List<int>? parseAppVersion(Object? value) {
  if (value is! String) return null;
  final trimmed = value.replaceAll(RegExp(r'^ +| +$'), '');
  if (trimmed.isEmpty || trimmed.length > 40) return null;
  final m = _versionPattern.firstMatch(trimmed);
  if (m == null) return null;
  return [for (var i = 1; i <= 4; i++) int.parse(m.group(i) ?? '0')];
}

/// -1 | 0 | 1, 어느 한쪽이라도 해석 불가면 null.
int? compareAppVersions(Object? a, Object? b) {
  final x = parseAppVersion(a), y = parseAppVersion(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < 4; i++) {
    if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return 0;
}

/// Play 스토어 주소(서버 `url.mobile` 이 없을 때).
const playStoreUrl =
    'https://play.google.com/store/apps/details?id=com.fentanest.mysafetyreport';

/// GitHub APK 설치본의 업데이트 주소.
const githubReleaseUrl =
    'https://github.com/Fentanest/safetyreport-mobile/releases/latest';

class UpdateRequirement {
  const UpdateRequirement({
    required this.locked,
    this.minVersion,
    this.url,
    this.message,
    this.decidedAt,
  });

  static const unlocked = UpdateRequirement(locked: false);

  final bool locked;
  final String? minVersion;
  final String? url;
  final String? message;

  /// 판정한 시각(epoch 밀리초).
  final int? decidedAt;

  static const prefsKey = 'community_update_requirement_v1';

  /// 이 isolate 의 화면용 판정. [load]·[applyStatus] 가 갱신한다.
  static final ValueNotifier<UpdateRequirement> current = ValueNotifier(
    unlocked,
  );

  static bool get isLocked => current.value.locked;

  Map<String, Object?> toJson() => {
    'locked': locked,
    'min_version': minVersion,
    'url': url,
    'message': message,
    'decided_at': decidedAt,
  };

  static UpdateRequirement fromJson(Object? raw) {
    if (raw is! Map || raw['locked'] != true) return unlocked;
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    return UpdateRequirement(
      locked: true,
      minVersion: s(raw['min_version']),
      url: s(raw['url']),
      message: s(raw['message']),
      decidedAt: raw['decided_at'] is num
          ? (raw['decided_at'] as num).toInt()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateRequirement &&
      other.locked == locked &&
      other.minVersion == minVersion &&
      other.url == url &&
      other.message == message;

  @override
  int get hashCode => Object.hash(locked, minVersion, url, message);

  /// 저장된 판정을 읽는다(다른 isolate 가 쓴 값을 보려고 reload). 읽지 못하면 마지막 메모리 값을 둔다.
  ///
  /// 읽을 때마다 저장된 `min_version` 과 **지금** 앱 버전을 다시 비교한다(D3): `cmp(지금, min) >= 0` 이면
  /// (업데이트를 마쳤으면) 잠금이 아니고 저장값도 지운다. 버전을 모르거나 해석할 수 없으면 저장된 판정 그대로.
  static Future<UpdateRequirement> load([SharedPreferences? prefs]) async {
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      await p.reload();
      final text = p.getString(prefsKey);
      var value = text == null ? unlocked : fromJson(jsonDecode(text));
      if (value.locked && !await _stillBelow(value)) {
        await p.remove(prefsKey);
        value = unlocked;
      }
      if (current.value != value) current.value = value;
      return value;
    } catch (_) {
      return current.value;
    }
  }

  /// 저장된 잠금이 지금 버전에도 해당하는가. 비교할 수 없으면 true(마지막 판정 유지).
  static Future<bool> _stillBelow(UpdateRequirement value) async {
    final cmp = compareAppVersions(await appVersion(), value.minVersion);
    return cmp == null || cmp < 0;
  }

  /// 정상 status(200, 형식 맞음)를 받은 뒤 새 판정. null = 마지막 판정 유지(6-2 표).
  static UpdateRequirement? decide(
    Map<String, Object?> status,
    String myVersion, {
    DateTime? now,
  }) {
    if (!status.containsKey('client_requirement')) return null;
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final req = status['client_requirement'];
    if (req == null) return UpdateRequirement(locked: false, decidedAt: at);
    if (req is! Map) return null;
    final min = req['min_version'];
    if (min is! Map || !min.containsKey('mobile')) return null;
    final mine = min['mobile'];
    if (mine == null) return UpdateRequirement(locked: false, decidedAt: at);
    if (mine is! String) return null;
    final cmp = compareAppVersions(myVersion, mine);
    if (cmp == null) return null;
    if (cmp >= 0) return UpdateRequirement(locked: false, decidedAt: at);
    final urls = req['url'];
    final url = urls is Map && urls['mobile'] is String
        ? urls['mobile'] as String
        : null;
    final message = req['message'];
    return UpdateRequirement(
      locked: true,
      minVersion: mine.trim(),
      url: url,
      message: message is String && message.trim().isNotEmpty
          ? message
          : null,
      decidedAt: at,
    );
  }

  /// 시험에서 내 버전을 바꾼다.
  @visibleForTesting
  static String? versionForTest;

  /// 내 버전(진입점이 [AppVersion.load] 로 읽어 둔 값). 모르면 null(판정하지 않음).
  static Future<String?> appVersion() async => versionForTest ?? AppVersion.value;

  /// 정상 status 응답을 받았을 때만 부른다. 반환: 판정이 바뀌었으면 새 값, 아니면 null.
  static Future<UpdateRequirement?> applyStatus(
    Map<String, Object?> status, {
    SharedPreferences? prefs,
    DateTime? now,
  }) async {
    final version = await appVersion();
    if (version == null) return null;
    final next = decide(status, version, now: now);
    if (next == null) return null;
    final before = await load(prefs);
    if (before == next) return null;
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      if (next.locked) {
        await p.setString(prefsKey, jsonEncode(next.toJson()));
      } else {
        await p.remove(prefsKey);
      }
    } catch (_) {
      return null;
    }
    current.value = next;
    return next;
  }
}
