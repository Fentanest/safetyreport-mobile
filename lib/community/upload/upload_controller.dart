// 앱 isolate 의 업로드 제어기(UC-1 §2 모바일). PC `community_uploader.start_background` 의 대응.
//
// - wake(trigger): 수집 완료·앱 복귀가 부른다. 실행 중이면 "다시 실행" 표시만 남기고(가장 넓은 트리거 하나), 끝난 뒤 한 번 더 돈다
//   — 표시를 지우는 시점이 실행 시작이라 실행 중에 들어온 새 알림을 잃지 않는다.
// - 재시도 타이머: 실행이 끝날 때마다 다음 깨울 시각(가장 이른 next_retry_at·cooldown 끝)을 계산해 타이머 하나만 둔다
//   (행마다 타이머 없음). 인증·동의·게이트 대기는 시각으로 깨우지 않는다(게이트가 다시 통과하면 catchUp·resume 이 깨운다).
//   다른 실행이 잡고 있으면 5초, 실패면 60초 뒤, 예산을 다 쓴(more_pending) 실행은 요청 간격 뒤 곧바로 이어서.
// - 네트워크 복구는 별도 플러그인 없이 cooldown 타이머의 탐색 요청(probing)과 앱 복귀가 맡는다.
// 백그라운드 isolate(WorkManager)는 이 제어기를 쓰지 않는다 — lease 로 앱 실행과 겹치지 않는다.
import 'dart:async';

import 'community_uploader.dart';

class CommunityUploadController {
  CommunityUploadController({DateTime Function()? now}) : _now = now ?? (() => DateTime.now().toUtc());

  static CommunityUploadController instance = CommunityUploadController();

  final DateTime Function() _now;
  Future<CommunityUploader> Function()? _build;
  Timer? _timer;
  bool _running = false;
  String? _pending;
  Future<void>? _loop;

  /// 넓은 트리거가 이긴다: recovery·manual 은 enqueue 를 하므로 realtime 보다 우선.
  static const Map<String, int> _rank = {'realtime': 0, 'recovery': 1, 'manual': 2};

  bool get isStarted => _build != null;

  /// 테스트·상태 표시용: 예약된 다음 실행 시각.
  DateTime? scheduledAt;

  /// Standalone writer 로 게이트를 통과한 뒤 시작한다. Client·데모에서는 시작하지 않는다(호출자 판단).
  void start(Future<CommunityUploader> Function() build) {
    _build = build;
    wake('recovery');
  }

  void stop() {
    _build = null;
    _timer?.cancel();
    _timer = null;
    scheduledAt = null;
    _pending = null;
  }

  void wake([String trigger = 'realtime']) {
    if (_build == null) return;
    final current = _pending;
    if (current == null || (_rank[trigger] ?? 0) > (_rank[current] ?? 0)) _pending = trigger;
    if (_running) return;
    _loop = _drainLoop();
  }

  /// 테스트용: 진행 중 루프가 끝날 때까지 기다린다.
  Future<void> idle() async {
    while (_loop != null) {
      final loop = _loop;
      await loop;
      if (identical(loop, _loop)) break;
    }
  }

  Future<void> _drainLoop() async {
    _running = true;
    _timer?.cancel();
    _timer = null;
    scheduledAt = null;
    UploadRunResult? result;
    CommunityUploader? uploader;
    try {
      while (_pending != null && _build != null) {
        final trigger = _pending!;
        _pending = null; // 실행 시작 때 지운다 — 실행 중 새 wake 는 다음 반복이 처리
        try {
          uploader = await _build!();
          result = await uploader.requestCommunityUpload(trigger);
        } catch (_) {
          result = null;
        }
      }
    } finally {
      _running = false;
    }
    if (_build == null || uploader == null) return;
    await _schedule(uploader, result);
  }

  Future<void> _schedule(CommunityUploader uploader, UploadRunResult? result) async {
    final outcome = result?.result;
    DateTime? due;
    if (outcome == 'needs_auth' || outcome == 'needs_consent' || outcome == 'blocked_gate') {
      due = null;
    } else if (outcome == 'busy_other_run') {
      due = _now().add(const Duration(seconds: 5));
    } else if (outcome == 'more_pending') {
      due = _now().add(minRequestInterval);
    } else {
      try {
        due = await uploader.nextDueAt();
      } catch (_) {
        due = null;
      }
      if (outcome == null || outcome == 'failed') {
        final fallback = _now().add(const Duration(seconds: 60));
        if (due == null || due.isBefore(fallback)) due = fallback;
      }
    }
    if (due == null || _build == null || _running) return;
    var delay = due.difference(_now());
    if (delay.isNegative) delay = Duration.zero;
    scheduledAt = due;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      scheduledAt = null;
      wake(outcome == 'more_pending' ? 'realtime' : 'recovery');
    });
  }
}
