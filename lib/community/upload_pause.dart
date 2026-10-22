// 업로드 일시 중지(서버 점검) — CLIENT-RULES 5절(2-9).
//
// 서버가 본체다: 중지 중이면 업로드·manifest·진행 보고가 DB 쓰기 전에 503 `maintenance` 로 끝난다.
// 이 앱은 그 판정을 미리 알고 덜 두드린다.
// - 받는 곳: status 의 `ingest.paused`·`pause_message`·`resume_at`(키가 없으면 저장값 유지), 업로드·manifest 의 503 maintenance.
// - 저장: community.db `meta.upload_pause`(백그라운드 isolate 도 같은 파일을 읽는다). 앱 재시작·백그라운드에서도 지킨다.
// - 중지 동안: 업로더·1회 전송·진행 보고를 멈춘다(업로드 시도 0회). 재개 시각이 있으면 그 시각 + 0~120초에
//   WorkManager 1회 작업으로 한 번만 깨워 status 를 확인한다. 재개 시각이 없으면 평소 status 확인을 기다린다.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'community_store.dart';

/// 재개 확인 1회 작업(WorkManager). `background_login_check.dart` 의 디스패처가 업로드 작업과 같은 경로로 처리한다.
const String uploadResumeTaskName = 'community-upload-resume';
const String uploadResumeUniqueName = 'community-upload-resume-v1';

/// 재개 시각 뒤 무작위로 더 기다리는 상한(모든 기기가 같은 초에 몰리지 않게).
const int uploadResumeJitterMaxSeconds = 120;

/// 재개 시각이 없는 503 의 기본 Retry-After(초). 이 값으로 타이머를 걸지는 않는다(평소 status 를 기다림).
const int uploadPauseDefaultRetrySeconds = 600;

class UploadPause {
  const UploadPause({
    required this.paused,
    required this.source,
    required this.savedAt,
    this.resumeAt,
    this.wakeAt,
    this.message,
  });

  final bool paused;

  /// 재개 시각(UTC epoch 초). null 이면 운영자가 올릴 때까지.
  final int? resumeAt;

  /// 재개 확인을 깨울 시각 = 재개 시각 + 0~120초(epoch 초). 같은 재개 시각이면 처음 뽑은 값을 유지한다.
  final int? wakeAt;

  /// 운영자 문구(평문). 화면에서 HTML 로 해석하지 않는다.
  final String? message;

  /// 'status' | '503'
  final String source;
  final int savedAt;

  static const metaKey = 'upload_pause';

  /// 이 isolate 의 화면 표시용(상단 배너). 저장·읽기 때마다 갱신한다.
  static final ValueNotifier<UploadPause?> current = ValueNotifier(null);

  /// 시험용 무작위 주입.
  @visibleForTesting
  static Random random = Random.secure();

  Map<String, Object?> toJson() => {
    'paused': paused,
    'resume_at': resumeAt,
    'wake_at': wakeAt,
    'message': message,
    'source': source,
    'saved_at': savedAt,
  };

  static UploadPause? fromJson(Object? raw) {
    if (raw is! Map || raw['paused'] != true) return null;
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    final message = raw['message'];
    final source = raw['source'];
    return UploadPause(
      paused: true,
      resumeAt: asInt(raw['resume_at']),
      wakeAt: asInt(raw['wake_at']),
      message: message is String && message.trim().isNotEmpty ? message : null,
      source: source is String ? source : 'status',
      savedAt: asInt(raw['saved_at']) ?? 0,
    );
  }

  /// 저장된 중지 판정(없으면 null). 깨진 값은 없는 것으로 본다(중지로 오인해 업로드를 영원히 막지 않는다).
  static Future<UploadPause?> read(CommunityStore store) async {
    UploadPause? value;
    try {
      final text = await store.meta(metaKey);
      value = text == null ? null : fromJson(jsonDecode(text));
    } catch (_) {
      value = null;
    }
    _publish(value);
    return value;
  }

  static Future<bool> isPaused(CommunityStore store) async =>
      (await read(store)) != null;

  static void _publish(UploadPause? value) {
    final before = current.value;
    if (before?.paused == value?.paused &&
        before?.resumeAt == value?.resumeAt &&
        before?.message == value?.message) {
      return;
    }
    current.value = value;
  }

  static int? _epoch(Object? iso) {
    if (iso is! String || iso.isEmpty) return null;
    final parsed = DateTime.tryParse(iso);
    return parsed == null ? null : parsed.toUtc().millisecondsSinceEpoch ~/ 1000;
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  /// status 응답 반영. 반환: 'paused'(중지 저장·갱신) | 'resumed'(중지가 풀림) | 'unchanged'.
  /// `ingest.paused` 키가 없거나 bool 이 아니면(서버가 설정을 읽지 못함) 저장값을 그대로 둔다.
  static Future<String> applyStatus(
    CommunityStore store,
    Map<String, Object?> status, {
    DateTime? now,
  }) async {
    final ingest = status['ingest'];
    if (ingest is! Map || !ingest.containsKey('paused')) return 'unchanged';
    final paused = ingest['paused'];
    if (paused is! bool) return 'unchanged';
    final before = await read(store);
    if (!paused) {
      if (before == null) return 'unchanged';
      await clear(store);
      return 'resumed';
    }
    await _save(
      store,
      before,
      resumeAt: _epoch(ingest['resume_at']),
      message: _text(ingest['pause_message']),
      source: 'status',
      now: now,
    );
    return before == null ? 'paused' : 'unchanged';
  }

  /// 업로드·manifest·진행 보고가 받은 503 `maintenance`. [error] 는 응답 본문의 `error` 객체.
  static Future<UploadPause> applyMaintenance(
    CommunityStore store,
    Map<String, Object?>? error, {
    DateTime? now,
  }) async {
    final before = await read(store);
    return _save(
      store,
      before,
      resumeAt: _epoch(error?['resume_at']),
      message: _text(error?['pause_message']),
      source: '503',
      now: now,
    );
  }

  /// 응답 본문(바이트·문자열·디코드된 값)에서 503 maintenance 의 `error` 객체를 꺼낸다. 아니면 null.
  static Map<String, Object?>? maintenanceError(Object? body) {
    Object? decoded = body;
    try {
      if (body is List<int>) decoded = jsonDecode(utf8.decode(body));
      if (body is String) decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final error = decoded['error'];
    if (error is! Map || error['code'] != 'maintenance') return null;
    return error.cast<String, Object?>();
  }

  static Future<UploadPause> _save(
    CommunityStore store,
    UploadPause? before, {
    required int? resumeAt,
    required String? message,
    required String source,
    DateTime? now,
  }) async {
    final t = (now ?? DateTime.now()).toUtc();
    final wakeAt = resumeAt == null
        ? null
        : (before?.resumeAt == resumeAt && before?.wakeAt != null)
        ? before!.wakeAt
        : resumeAt + random.nextInt(uploadResumeJitterMaxSeconds + 1);
    final value = UploadPause(
      paused: true,
      resumeAt: resumeAt,
      wakeAt: wakeAt,
      message: message,
      source: source,
      savedAt: t.millisecondsSinceEpoch ~/ 1000,
    );
    await store.setMeta(metaKey, jsonEncode(value.toJson()));
    _publish(value);
    if (wakeAt != null && wakeAt != before?.wakeAt) {
      await scheduleResumeWake(value, now: t);
    } else if (wakeAt == null && before?.wakeAt != null) {
      await cancelResumeWake();
    }
    return value;
  }

  static Future<void> clear(CommunityStore store) async {
    try {
      await store.db.delete('meta', where: 'key=?', whereArgs: [metaKey]);
    } catch (_) {}
    _publish(null);
    await cancelResumeWake();
  }

  /// 재개 확인까지 남은 시간(재개 시각이 없으면 null — 타이머를 걸지 않는다).
  Duration? wakeDelay(DateTime now) {
    final at = wakeAt;
    if (at == null) return null;
    final left = at - now.toUtc().millisecondsSinceEpoch ~/ 1000;
    return Duration(seconds: left < 0 ? 0 : left);
  }

  /// 시험에서 WorkManager 대신 쓴다.
  @visibleForTesting
  static Future<void> Function(Duration delay)? scheduleForTest;

  /// 재개 확인 1회 작업(초기 지연 = 남은 시간 + 지터). 연장되면 새 시각으로 바꾼다(replace).
  static Future<void> scheduleResumeWake(UploadPause pause, {DateTime? now}) async {
    final delay = pause.wakeDelay(now ?? DateTime.now());
    // 재개 시각이 이미 지났는데도 중지로 남아 있으면(서버가 판정을 못 줌) 곧바로 다시 깨우지 않는다 —
    // 평소 status 확인(주기 작업·앱 복귀)이 풀어 준다. 같은 자리에서 도는 재예약을 막는다.
    if (delay == null || delay == Duration.zero) return;
    final hook = scheduleForTest;
    if (hook != null) {
      await hook(delay);
      return;
    }
    try {
      await Workmanager().registerOneOffTask(
        uploadResumeUniqueName,
        uploadResumeTaskName,
        initialDelay: delay,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (_) {}
  }

  static Future<void> cancelResumeWake() async {
    if (scheduleForTest != null) return;
    try {
      await Workmanager().cancelByUniqueName(uploadResumeUniqueName);
    } catch (_) {}
  }
}

/// 상단 배너 문구(2-13). 시각은 기기 시간대 KST "오전/오후 h시 m분", 오늘이 아니면 "10월 23일 오전 9시".
String uploadPauseBannerText(UploadPause pause, {DateTime? now}) {
  final at = pause.resumeAt;
  if (at == null) {
    return '서버 점검 중입니다. 신고 업로드를 잠시 멈췄고, 점검이 끝나면 자동으로 다시 올립니다.';
  }
  return '서버 점검 중입니다. 신고 업로드를 잠시 멈췄고, ${kstClockLabel(at, now: now)}에 자동으로 다시 올립니다.';
}

/// epoch 초 → KST "오후 3시 30분" / 날짜가 오늘(KST)이 아니면 "10월 23일 오전 9시". 0분이면 분을 뺀다.
String kstClockLabel(int epochSeconds, {DateTime? now}) {
  const kst = Duration(hours: 9);
  final t = DateTime.fromMillisecondsSinceEpoch(
    epochSeconds * 1000,
    isUtc: true,
  ).add(kst);
  final today = (now ?? DateTime.now()).toUtc().add(kst);
  final sameDay =
      t.year == today.year && t.month == today.month && t.day == today.day;
  final half = t.hour < 12 ? '오전' : '오후';
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final clock = t.minute == 0
      ? '$half $hour12시'
      : '$half $hour12시 ${t.minute}분';
  return sameDay ? clock : '${t.month}월 ${t.day}일 $clock';
}
