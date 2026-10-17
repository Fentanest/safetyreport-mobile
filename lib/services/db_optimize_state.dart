// DB 최적화 작업 공유 상태(2026-10-17 명세 3절, 서버 services/db_optimize.py 와 같은 뜻).
//
// import 순환을 피하려고 UI·DB·작업 로직이 함께 쓰는 최소 상태만 둔다:
//   LocalDbService(스키마 업그레이드 단계 기록) → 여기,
//   DbOptimize(진행·로그) → 여기,
//   MaintenanceService(표시줄 작업으로 변환)·위젯 → 여기.
// 서버 `db_optimize._state`·`job_for_status()` 와 같은 모양이다.
import 'package:flutter/foundation.dart' show ValueNotifier;
class DbOptimizeState {
  DbOptimizeState._();

  /// DB 메타(`sync_meta`) 키. 값은
  /// {"target","cursor","done","total","stats":{reused,refetched,changed,events,skipped}}
  /// 서버 `mysafety_sync_meta.detail_raw_optimize` 와 같은 키·같은 모양이다.
  static const metaKey = 'detail_raw_optimize';

  /// 최적화 때문에 크롤 시작을 뒤로 미뤘을 때 크롤 창 로그에 남기는 한 줄(명세 3-3 고정 문구, 서버와 같은 문구).
  static const deferLogLine = 'DB 최적화 중입니다. 최적화가 끝난 뒤 크롤링을 시작합니다.';

  /// 원본 표에 없던 신고를 다시 받아올 때 원본 표 `source` 열 값(명세 3-2, 서버와 같음).
  static const backfillSource = 'backfill';

  /// 공유 캡처 trigger. 바뀐 신고만 새 completed_observation 이 나간다(서버와 같음).
  static const reparseTrigger = 'reparse';

  static const jobKey = 'db_optimize';
  static const jobLabel = 'DB 최적화 중입니다…';

  static const _logKeep = 50;

  static String _state = 'idle'; // idle | running | paused | completed | error
  static int _total = 0;
  static int _done = 0;
  static String _stage = '';
  static String _message = '';
  static String _finishedAt = '';
  static final List<String> _log = [];

  /// UI 갱신용. 값이 바뀔 때마다 +1. MaintenanceStatusBar 가 구독한다.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static bool get isRunning => _state == 'running' || _state == 'paused';

  static String get state => _state;
  static String get stage => _stage;

  static void _bump() => revision.value++;

  static void update({
    String? state,
    int? total,
    int? done,
    String? stage,
    String? message,
    String? finishedAt,
  }) {
    if (state != null) _state = state;
    if (total != null) _total = total;
    if (done != null) _done = done;
    if (stage != null) _stage = stage;
    if (message != null) _message = message;
    if (finishedAt != null) _finishedAt = finishedAt;
    _bump();
  }

  static String _nowText() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  /// 단계 로그에 시각+문구 한 줄을 남긴다(최근 50줄만). 스키마 업그레이드 단계도 여기로 기록한다(서버와 같음).
  static void appendLog(String message) {
    _log.add('${_nowText()} $message');
    while (_log.length > _logKeep) {
      _log.removeAt(0);
    }
    _bump();
  }

  /// `LocalDbService` 스키마 업그레이드가 부르는 기록 지점. 최적화 작업 전에도 로그가 남는다.
  static void recordMigrationEvent(String message) => appendLog(message);

  /// 값이 바뀌지 않아도 화면을 다시 그리게 한다(업그레이드 시작·끝 전환용).
  static void notifyChanged() => _bump();

  /// `maintenance_service.status()` 가 그대로 싣는 작업 dict. 할 일 없으면 null(서버와 같음).
  static Map<String, dynamic>? jobForStatus() {
    if (_state == 'idle' && _log.isEmpty) return null;
    return {
      'key': jobKey,
      'label': jobLabel,
      'state': _state,
      'total': _total,
      'done': _done,
      'stage': _stage,
      'message': _message,
      'log': List<String>.from(_log),
      'finished_at': _finishedAt,
    };
  }

  static void resetForTest() {
    _state = 'idle';
    _total = 0;
    _done = 0;
    _stage = '';
    _message = '';
    _finishedAt = '';
    _log.clear();
    _bump();
  }
}
