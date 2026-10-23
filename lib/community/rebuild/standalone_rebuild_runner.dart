import '../manifest_result.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../services/sync_engine.dart';
import 'community_rebuild.dart';
import 'rebuild_coordinator.dart';

/// 다시 불러오기 진행 표시(대시보드 카드·알림 공통). 실제 `rebuild_items` 건수만 쓴다(과장된 진행률 금지).
@immutable
class RebuildProgress {
  const RebuildProgress({
    required this.state,
    required this.executing,
    required this.stopping,
    required this.waitingForWorker,
    required this.listComplete,
    required this.listed,
    required this.fetched,
    required this.failedPermanent,
    required this.retryable,
    required this.lastError,
    required this.notice,
    required this.pendingUploads,
  });

  factory RebuildProgress.of(CommunityRebuild r) {
    final c = r.counts();
    return RebuildProgress(
      state: r.state,
      executing: r.isExecuting,
      stopping: r.stopping,
      waitingForWorker: r.waitingForWorker,
      listComplete: r.job?['list_complete'] == 1,
      listed: c['listed'] ?? 0,
      fetched: c['fetched'] ?? 0,
      failedPermanent: c['failed_permanent'] ?? 0,
      retryable: c['failed_retryable'] ?? 0,
      lastError: r.job?['last_error']?.toString(),
      notice: r.notice,
      pendingUploads: r.pendingUploads,
    );
  }

  final String state;
  final bool executing;
  final bool stopping;
  final bool waitingForWorker;
  final bool listComplete;
  final int listed;
  final int fetched;
  final int failedPermanent;
  final int retryable;
  final String? lastError;
  final String? notice;
  final int? pendingUploads;

  bool get done => RebuildStates.terminalOk.contains(state);
  bool get userPaused =>
      state == RebuildStates.paused && lastError == 'user_paused';

  /// 영구 누락이 있어 사용자의 확인을 기다린다(`validating` + failed_permanent).
  bool get needsGapConsent =>
      !executing && state == RebuildStates.validating && failedPermanent > 0;

  /// 상세 수집 단계의 처리 건수(성공 + 영구 실패) / 목록 건수. 목록을 다 받기 전에는 null(막대 없이 표시).
  double? get fraction {
    if (!listComplete || listed <= 0) return null;
    if (done) return 1;
    return ((fetched + failedPermanent) / listed).clamp(0.0, 1.0);
  }

  int get processed => fetched + failedPermanent;

  String get headline {
    if (stopping) return '중단 확인 중';
    if (waitingForWorker && !executing) return '이전 작업이 남아 있습니다';
    if (done) {
      return state == RebuildStates.completedWithGaps
          ? '완료 · 가져오지 못한 신고 $failedPermanent건은 기존 자료 유지'
          : '완료';
    }
    if (needsGapConsent) return '가져오지 못한 신고 $failedPermanent건 — 확인 필요';
    if (executing) {
      return switch (state) {
        RebuildStates.preparingBackup => '백업 준비 중',
        RebuildStates.running when !listComplete => '전체 신고 확인 중',
        RebuildStates.running => '상세 수집 중 $processed/$listed건',
        RebuildStates.validating || RebuildStates.committing => '새 저장 구조 반영 중',
        _ => '준비 중',
      };
    }
    return switch (state) {
      RebuildStates.paused when userPaused => '일시정지됨',
      RebuildStates.paused => '중단됨 — 이어서 진행할 수 있습니다',
      RebuildStates.failed => '실패 — 다시 시도할 수 있습니다',
      RebuildStates.prerequisitesRequired => '준비 필요 — 연결을 확인한 뒤 이어서 진행해 주세요',
      RebuildStates.waitingRetry => '자동 재시도 대기 중',
      _ => '시작 대기',
    };
  }

  /// 건수 줄(목록을 받기 전·완료 뒤에도 실제 값만).
  String get countsLine {
    if (listed <= 0) return '';
    final remaining = (listed - processed).clamp(0, listed);
    return '성공 $fetched건 · 실패 $failedPermanent건 · 남은 $remaining건'
        '${retryable > 0 ? ' (재시도 대기 $retryable건)' : ''}';
  }
}

/// 다시 불러오기 알림(진행 중 FGS 알림 갱신 + 끝났을 때 한 번). 기본값은 기존 MethodChannel·FGS 알림 체계.
class RebuildNotificationSink {
  const RebuildNotificationSink();

  static const _channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  Future<void> progress(
    String title,
    String message,
    int? current,
    int? total,
  ) => SyncEngine.updateFgsNotification(
    title: title,
    message: message,
    current: current,
    total: total,
  );

  Future<void> milestone(String title, String body) async {
    try {
      await _channel.invokeMethod('showNotification', {
        'title': title,
        'body': body,
        'nav_tab': 0, // 대시보드(진행 카드)
      });
    } catch (_) {}
  }
}

/// Standalone 신고 내역 다시 불러오기(1회 초기화)를 화면과 무관하게 백그라운드로 진행하는 앱 전역 진입점.
///
/// 2026-10-11 사용자 결정: 새 버전 첫 실행 때 안내를 한 번 보이고 '확인' 뒤 바로 메인으로 간다. 진행은 대시보드 카드와 알림에서 보고,
/// 앱을 닫았다 열면 같은 run 으로 이어서 진행한다. 상태기계·저장·재개는 [CommunityRebuild] 그대로다.
class StandaloneRebuildRunner extends ChangeNotifier {
  StandaloneRebuildRunner({
    RebuildNotificationSink sink = const RebuildNotificationSink(),
    this.retryDelay = const Duration(seconds: 60),
    this.maxWorkerRetries = 15,
    DateTime Function()? now,
  }) : _sink = sink,
       _now = now ?? DateTime.now;

  static StandaloneRebuildRunner instance = StandaloneRebuildRunner();

  final RebuildNotificationSink _sink;
  final DateTime Function() _now;

  static const prerequisiteRetryDelays = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  static const leaseExpiryMargin = Duration(seconds: 5);

  /// 이전 프로세스·다른 작업의 lease 가 남아 시작하지 못했을 때 다시 시도하는 간격·횟수(기존 lease 최대 10~30분).
  final Duration retryDelay;
  final int maxWorkerRetries;

  final RebuildCoordinator _coordinator = RebuildCoordinator();
  CommunityRebuild? _current;
  CommunityRebuild? get current => _current;

  /// 실행이 끝날 때(완료·일시정지·실패) 목록·요약을 다시 읽는다. main 이 `ReportProvider.refreshAll` 을 단다.
  Future<void> Function()? onRunFinished;

  bool _completionDismissed = false;
  bool get completionDismissed => _completionDismissed;
  Timer? _retryTimer;
  int _workerRetries = 0;
  int _prerequisiteRetries = 0;
  int _runVersion = 0;
  bool _pauseRequested = false;
  DateTime? _nextRetryAt;
  DateTime? get nextRetryAt => _nextRetryAt;
  bool _retryStopped = false;
  bool get retryStopped => _retryStopped;
  String? _retryNotice;
  String? get retryNotice => _retryNotice;
  bool get waitingToRetry => _retryTimer?.isActive ?? false;
  bool _sawBusy = false;
  bool _wasExecuting = false;
  String? _lastProgressText;
  String? _lastMilestone;

  bool get isExecuting => _current?.isExecuting ?? false;

  /// 사용자가 시작한 다시 불러오기가 아직 끝나지 않았다(진행·중단·실패·확인 대기).
  bool get pending {
    final r = _current;
    return r != null && !RebuildStates.terminalOk.contains(r.state);
  }

  /// 대시보드 카드를 보여 줄지. 완료는 사용자가 닫을 때까지 남긴다.
  bool get visible {
    final r = _current;
    if (r == null) return false;
    if (RebuildStates.terminalOk.contains(r.state)) {
      return !_completionDismissed && r.job != null;
    }
    return true;
  }

  void dismissCompletion() {
    _completionDismissed = true;
    notifyListeners();
  }

  /// 같은 범위면 같은 객체(실행 중인 Future 를 잃지 않는다). 범위가 바뀌면 이전 작업은 중단 요청 뒤 해제된다.
  CommunityRebuild attach(String scope, CommunityRebuild Function() create) {
    final r = _coordinator.attach(scope, create);
    _adopt(r);
    return r;
  }

  /// 조정자 없이 이 객체를 현재 작업으로 둔다(판정을 주입한 게이트·시험).
  void adopt(CommunityRebuild r) => _adopt(r);

  void _adopt(CommunityRebuild r) {
    if (identical(r, _current)) return;
    _current?.removeListener(_onChange);
    _cancelRetry();
    _runVersion++;
    _workerRetries = 0;
    _prerequisiteRetries = 0;
    _pauseRequested = false;
    _retryStopped = false;
    _sawBusy = false;
    _wasExecuting = r.isExecuting;
    _completionDismissed = false;
    _lastProgressText = null;
    _lastMilestone = null;
    _current = r;
    r.addListener(_onChange);
    notifyListeners();
  }

  /// 이 기기에서 다시 불러오기가 필요 없을 때(완료·새 설치·Client·데모) 카드를 치운다. 객체 해제는 조정자가 맡는다.
  void clear() {
    if (_current == null) return;
    if (_current!.isExecuting) return; // 실행 중인 작업의 표시를 숨기지 않는다.
    _current!.removeListener(_onChange);
    _cancelRetry();
    _runVersion++;
    _current = null;
    notifyListeners();
  }

  /// 수동 동기화를 막는 이유(없으면 null). 진행 중이거나 끝나지 않았으면 일반 동기화는 [SyncEngine] 이 어차피 거절한다 —
  /// 화면은 시작 전에 이 문구로 이유를 보인다.
  String? syncBlockReason() {
    final r = _current;
    if (r == null) return null;
    if (r.isExecuting) {
      return '신고 내역 다시 불러오기가 진행 중입니다. 끝나면 동기화할 수 있습니다. 진행 상황은 대시보드에서 볼 수 있습니다.';
    }
    if (!RebuildStates.terminalOk.contains(r.state)) {
      return '신고 내역 다시 불러오기(1회)를 먼저 마쳐야 동기화할 수 있습니다. 다시 불러오기 카드에서 이어서 진행해 주세요.';
    }
    return null;
  }

  /// DB 내보내기·백업·복원·모드 전환을 막는 이유(진행 중일 때만). 중단·실패 상태의 DB 는 일관되므로 막지 않는다.
  String? fileOperationBlockReason(String action) {
    if (!isExecuting) return null;
    return '신고 내역 다시 불러오기가 진행 중이라 $action 할 수 없습니다. '
        '대시보드의 다시 불러오기 카드에서 일시정지하거나 끝난 뒤 다시 시도해 주세요.';
  }

  /// 백그라운드로 시작(또는 같은 run 이어서). 이미 실행 중이면 그 실행을 그대로 둔다(single-flight).
  void runInBackground({String confirmedBy = 'user', bool userAction = true}) {
    final r = _current;
    if (_disposed || r == null || r.isExecuting) return;
    _cancelRetry();
    _runVersion++;
    if (userAction) {
      _workerRetries = 0;
      _prerequisiteRetries = 0;
      _pauseRequested = false;
    }
    _retryStopped = false;
    _completionDismissed = false;
    unawaited(_run(r, confirmedBy));
  }

  /// 누락 수락(사용자 명시 동의, `completed_with_gaps`).
  void acceptGapsInBackground() {
    final r = _current;
    if (r == null) return;
    _cancelRetry();
    _runVersion++;
    unawaited(_guard(r, r.acceptGaps));
  }

  void requestPause() {
    _pauseRequested = true;
    _cancelRetry();
    _runVersion++;
    _current?.requestPause();
    notifyListeners();
  }

  /// 앱 시작·게이트 통과 때 이어서 진행할지: 안내를 확인한 뒤 끝나지 않았고, 사용자가 멈추지 않았고, 누락 동의를 기다리지 않을 때.
  static bool shouldAutoResume(CommunityRebuild r) {
    if (r.isExecuting) return false;
    final p = RebuildProgress.of(r);
    if (p.done || p.userPaused || p.needsGapConsent) return false;
    return true;
  }

  /// [shouldAutoResume] 이면 같은 run 으로 백그라운드 재개. 반환: 재개를 요청했는가.
  bool resumeIfDue() {
    final r = _current;
    if (r == null ||
        waitingToRetry ||
        _retryStopped ||
        _pauseRequested ||
        !shouldAutoResume(r)) {
      return false;
    }
    runInBackground(confirmedBy: 'resume', userAction: false);
    return true;
  }

  Future<void> _run(CommunityRebuild r, String confirmedBy) =>
      _guard(r, () => r.start(confirmedBy: confirmedBy));

  Future<void> _guard(
    CommunityRebuild r,
    Future<Object?> Function() body,
  ) async {
    final version = _runVersion;
    try {
      await body();
    } catch (_) {
      // 상태기계가 오류를 job 에 남긴다. 여기서는 표시만 갱신한다.
    }
    if (!_isCurrent(r, version)) return;
    await _scheduleRetry(r, version);
    if (!_isCurrent(r, version)) return;
    notifyListeners();
  }

  bool _isCurrent(CommunityRebuild r, int version) =>
      !_disposed && identical(r, _current) && version == _runVersion;

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRetryAt = null;
    _retryNotice = null;
  }

  Future<void> _scheduleRetry(CommunityRebuild r, int version) async {
    if (_pauseRequested || !shouldAutoResume(r)) return;
    final manifestUnavailable = r.waitingForManifest;
    if (!r.waitingForWorker && !manifestUnavailable) return;
    Duration delay;
    int attempt;
    int limit;
    if (r.waitingForWorker) {
      if (_workerRetries >= maxWorkerRetries) {
        _stopRetry();
        return;
      }
      DateTime? expires;
      try {
        expires = await r.workerLeaseExpiresAt();
      } catch (_) {
        if (_isCurrent(r, version)) _stopRetry();
        return;
      }
      if (!_isCurrent(r, version) || _pauseRequested || !shouldAutoResume(r)) {
        return;
      }
      final remaining = expires?.add(leaseExpiryMargin).difference(_now());
      delay = remaining != null && remaining > Duration.zero
          ? remaining
          : retryDelay;
      attempt = ++_workerRetries;
      limit = maxWorkerRetries;
    } else {
      delay = r.manifestFailure?.status == ManifestStatus.busyUploadLease
          ? prerequisiteRetryDelays.first
          : prerequisiteRetryDelays[_prerequisiteRetries.clamp(
              0,
              prerequisiteRetryDelays.length - 1,
            )];
      _prerequisiteRetries++;
      attempt = _prerequisiteRetries;
      limit = prerequisiteRetryDelays.length;
    }
    _nextRetryAt = _now().add(delay);
    final at = _nextRetryAt!.toLocal();
    final time =
        '${at.month}/${at.day} '
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}';
    _retryNotice =
        '${r.waitingForWorker ? '이전 작업이 끝나기를 기다리고 있습니다.' : '공유 목록을 확인하지 못했습니다.'} '
        '$time에 자동으로 다시 시도합니다${r.waitingForWorker ? ' ($attempt/$limit회)' : ''}.';
    _retryTimer = Timer(delay, () {
      if (!_isCurrent(r, version)) return;
      _cancelRetry();
      if (!_pauseRequested && shouldAutoResume(r)) {
        runInBackground(confirmedBy: 'resume', userAction: false);
      }
      notifyListeners();
    });
    unawaited(_sink.milestone('신고 내역 다시 불러오기 — 재시도 대기', _retryNotice!));
  }

  void _stopRetry() {
    _cancelRetry();
    _retryStopped = true;
    _retryNotice =
        '자동 재시도를 중단했습니다. 연결과 작업 상태를 확인한 뒤 '
        '대시보드의 다시 불러오기 카드에서 다시 시도해 주세요. 기존 자료는 그대로입니다.';
    unawaited(_sink.milestone('신고 내역 다시 불러오기 — 확인 필요', _retryNotice!));
  }

  void _onChange() {
    final r = _current;
    if (r == null) return;
    final p = RebuildProgress.of(r);
    if (p.executing || p.done || p.userPaused || p.needsGapConsent) {
      _cancelRetry();
      _retryStopped = false;
    }
    if (p.executing && r.isBusy) _sawBusy = true;
    if (p.executing) {
      _updateProgressNotification(p);
    } else if (_wasExecuting) {
      _lastProgressText = null;
      if (_sawBusy) _notifyMilestone(r, p);
      _sawBusy = false; // 다음 실행은 실제로 진행했을 때만 다시 알린다.
      final refresh = onRunFinished;
      if (refresh != null) unawaited(refresh().catchError((_) {}));
    }
    _wasExecuting = p.executing;
    notifyListeners();
  }

  void _updateProgressNotification(RebuildProgress p) {
    final text = p.countsLine.isEmpty
        ? p.headline
        : '${p.headline}\n${p.countsLine}';
    // FGS 는 수집 단계에서 열린다 — 열리기 전에 보낸 문구는 버려지므로 FGS 상태도 비교에 넣는다.
    final key = '${SyncEngine.fgsActive.value}|$text';
    if (key == _lastProgressText) return;
    _lastProgressText = key;
    unawaited(
      _sink.progress(
        '신고 내역 다시 불러오기',
        text,
        p.fraction == null ? null : p.processed,
        p.fraction == null ? null : p.listed,
      ),
    );
  }

  void _notifyMilestone(CommunityRebuild r, RebuildProgress p) {
    if (p.userPaused) return;
    final key = '${r.job?['run_id']}:${p.state}:${p.lastError}';
    if (key == _lastMilestone) return;
    final (String, String)? message = switch (p.state) {
      RebuildStates.completed => (
        '신고 내역 다시 불러오기 완료',
        '저장된 신고를 새 기준으로 다시 불러왔습니다.'
            '${(p.pendingUploads ?? 0) > 0 ? ' 공유 전송 대기 ${p.pendingUploads}건은 이어서 보냅니다.' : ''}',
      ),
      RebuildStates.completedWithGaps => (
        '신고 내역 다시 불러오기 완료(일부 누락)',
        '가져오지 못한 신고 ${p.failedPermanent}건은 기존 자료를 그대로 두었습니다.',
      ),
      RebuildStates.validating when p.failedPermanent > 0 => (
        '신고 내역 다시 불러오기 — 확인 필요',
        '가져오지 못한 신고 ${p.failedPermanent}건이 있습니다. 대시보드에서 확인한 뒤 마무리할 수 있습니다.',
      ),
      RebuildStates.failed || RebuildStates.paused => (
        '신고 내역 다시 불러오기 중단',
        '${p.notice ?? '다시 불러오기를 끝내지 못했습니다.'} 대시보드에서 다시 시도할 수 있습니다. 기존 자료는 그대로입니다.',
      ),
      _ => null,
    };
    if (message == null) return;
    _lastMilestone = key;
    unawaited(_sink.milestone(message.$1, message.$2));
  }

  bool _disposed = false;

  /// 실행 중인 작업이 늦게 끝나도(시험·앱 종료) 해제된 실행기에 알리지 않는다.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRetry();
    _runVersion++;
    _current?.removeListener(_onChange);
    super.dispose();
  }
}
