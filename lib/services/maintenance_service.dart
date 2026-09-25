// 업데이트 뒤 한 번 훑는 작업과 진행 상태 — 서버 services/maintenance_service.py 와 같은 역할(2026-09-25).
//
// Standalone: 앱을 열 때 촬영 시각을 아직 못 읽은 주정차 신고(신고일 6개월 이내)의 사진 촬영 시각을 채운다.
//   한 건씩 간격을 두고, 동기화 중이면 기다리고, 백업·복원이 DB 를 닫으려 하면 멈춘다(다음에 열 때 남은 것부터).
// Client: 서버가 같은 작업을 하므로 서버 진행 상태(/api/v1/maintenance/status)를 읽어 보여 준다.
// 화면 하단 한 줄 표시줄(widgets/maintenance_status_bar.dart)이 [jobs] 를 그린다.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'local_db_service.dart';
import 'local_geocode_service.dart';
import 'photo_capture_time.dart';
import 'standalone_auto_sync_service.dart';
import 'sync_engine.dart';

class MaintenanceJob {
  const MaintenanceJob({
    required this.key,
    required this.label,
    required this.state,
    this.total = 0,
    this.done = 0,
    this.current = '',
    this.message = '',
  });

  final String key;
  final String label;

  /// running | paused | completed
  final String state;
  final int total;
  final int done;
  final String current;
  final String message;

  bool get active => state == 'running' || state == 'paused';

  factory MaintenanceJob.fromJson(Map<String, dynamic> j) => MaintenanceJob(
    key: '${j['key'] ?? ''}',
    label: '${j['label'] ?? ''}',
    state: '${j['state'] ?? ''}',
    total: int.tryParse('${j['total'] ?? 0}') ?? 0,
    done: int.tryParse('${j['done'] ?? 0}') ?? 0,
    current: '${j['current'] ?? ''}',
    message: '${j['message'] ?? ''}',
  );

  /// 표시줄 한 줄: `주정차 사진 촬영 시각 읽기 · 132/480 · SPP-… · 메시지`
  String get line => [
    label,
    if (total > 0) '$done/$total',
    if (current.isNotEmpty) current,
    if (message.isNotEmpty) message,
  ].join(' · ');
}

class MaintenanceService {
  MaintenanceService._();

  static const photoJobKey = 'photo_capture_time';
  static const photoJobLabel = '주정차 사진 촬영 시각 읽기';
  static const _interval = Duration(milliseconds: 400);
  static const _syncWait = Duration(seconds: 5);

  /// 로컬(Standalone) 사진 작업 상태. null 이면 할 일 없음.
  static final ValueNotifier<MaintenanceJob?> photoJob = ValueNotifier(null);
  static Future<void>? _running;
  static bool _starting = false;

  static bool get _syncing =>
      SyncEngine.isRunning || StandaloneAutoSyncService.isRunning;

  /// 대상이 있으면 백그라운드로 시작한다(이미 돌고 있으면 그대로). [wait] 은 테스트용.
  static Future<void> startPhotoBackfill({
    Future<String?> Function(String url)? fetch,
    Duration interval = _interval,
    Duration syncWait = _syncWait,
    bool Function()? syncing,
    bool wait = false,
  }) async {
    if (_running != null) {
      if (wait) await _running;
      return;
    }
    if (_starting) return;
    _starting = true;
    final List<({String id, String photos, String reportNumber})> rows;
    try {
      rows = await LocalDbService.pendingPhotoRows();
    } catch (_) {
      return; // DB 를 닫는 중(백업·복원) 등 — 다음 새로고침 때 다시
    } finally {
      _starting = false;
    }
    if (rows.isEmpty) return;
    photoJob.value = MaintenanceJob(
      key: photoJobKey,
      label: photoJobLabel,
      state: 'running',
      total: rows.length,
    );
    final future =
        LocalDbService.runBackgroundWork(
          () =>
              _run(rows, fetch, interval, syncWait, syncing ?? () => _syncing),
        ).catchError((Object _) {
          photoJob.value = null; // DB 를 닫는 중이면 다음 새로고침 때 다시
        });
    _running = future;
    unawaited(future.whenComplete(() => _running = null));
    if (wait) await future;
  }

  static Future<void> _run(
    List<({String id, String photos, String reportNumber})> rows,
    Future<String?> Function(String url)? fetch,
    Duration interval,
    Duration syncWait,
    bool Function() syncing,
  ) async {
    var filled = 0;
    var failed = 0;
    for (var i = 0; i < rows.length; i++) {
      if (LocalDbService.closeRequested) {
        photoJob.value = null; // 백업·복원이 DB 를 닫는다 — 다음에 열 때 남은 것부터
        return;
      }
      while (syncing() && !LocalDbService.closeRequested) {
        photoJob.value = MaintenanceJob(
          key: photoJobKey,
          label: photoJobLabel,
          state: 'paused',
          total: rows.length,
          done: i,
          message: '동기화가 끝나면 이어서 합니다',
        );
        await Future<void>.delayed(syncWait);
      }
      final row = rows[i];
      photoJob.value = MaintenanceJob(
        key: photoJobKey,
        label: photoJobLabel,
        state: 'running',
        total: rows.length,
        done: i,
        current: row.reportNumber.isEmpty ? row.id : row.reportNumber,
      );
      try {
        final capture = await collectPhotoCapture(row.photos, fetch: fetch);
        if (capture != null) {
          await LocalDbService.setPhotoCapture(row.id, capture);
          filled++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
      if (interval > Duration.zero) await Future<void>.delayed(interval);
    }
    photoJob.value = MaintenanceJob(
      key: photoJobKey,
      label: photoJobLabel,
      state: 'completed',
      total: rows.length,
      done: rows.length,
      message: '$filled건 채움${failed > 0 ? ', $failed건은 다음에 다시' : ''}',
    );
  }

  /// Standalone 표시줄용: 사진 작업 + 지도 좌표 채우기(LocalGeocodeService) 진행.
  static List<MaintenanceJob> localJobs() {
    final jobs = <MaintenanceJob>[];
    final photo = photoJob.value;
    if (photo != null) jobs.add(photo);
    final geo = LocalGeocodeService.currentProgress();
    if (geo.state == 'running' || geo.state == 'queued') {
      jobs.add(
        MaintenanceJob(
          key: 'geocode',
          label: '지도 좌표 채우기',
          state: geo.state == 'running' ? 'running' : 'paused',
          total: geo.total,
          done: geo.processed,
          message: geo.state == 'queued' ? '동기화가 끝나면 이어서 합니다' : '',
        ),
      );
    }
    return jobs;
  }

  /// 서버 응답(`{active, jobs}`)을 표시줄 작업 목록으로.
  static List<MaintenanceJob> jobsFromServer(Map<String, dynamic>? data) => [
    for (final j in (data?['jobs'] as List? ?? const []))
      if (j is Map) MaintenanceJob.fromJson(Map<String, dynamic>.from(j)),
  ];

  @visibleForTesting
  static void resetForTest() {
    photoJob.value = null;
    _running = null;
    _starting = false;
  }
}
