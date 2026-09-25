import '../models/rating_lookup.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/report.dart';
import 'app_prefs_keys.dart';
import 'duplicate_projection_service.dart';
import 'local_db_service.dart';
import 'maintenance_service.dart';
import 'pending_changes_store.dart';
import 'standalone_api_service.dart';
import 'review_prompt_service.dart';
import 'standalone_auth_service.dart';
import 'standalone_parser.dart';

/// 동기화 이벤트 타입
enum SyncEventType { log, progress, done, error }

/// 신고 변경 종류 — pending_crawl_changes / 알림 / 카드 시트 공통 식별자.
/// 모든 곳에서 magic string 대신 이 상수 참조 (오타 방지 + 일관성).
class ChangeType {
  /// 신규 신고 (DB 에 없던 ID)
  static const newReport = '신규';

  /// 처리상태 변경 (DB 에 있던 ID + 처리상태가 바뀜)
  static const statusChanged = '처리변경';

  /// 사용자가 알림 탭으로 명시적 요청한 개별 fetch — 처리상태 변동 없음
  /// (Standalone 모드 _tryFetchSingle 에서 사용)
  static const individualConfirm = '개별확인';
}

class SyncEvent {
  final SyncEventType type;
  final String message;
  final int current;
  final int total;
  SyncEvent({
    required this.type,
    this.message = '',
    this.current = 0,
    this.total = 0,
  });
}

/// 동기화 엔진
/// 안전신문고 목록 API → 상세 API → 파싱 → 로컬 DB 저장
class SyncEngine {
  static bool _running = false;

  /// 끝날 때까지 true — [stop] 은 멈춤을 요청할 뿐이라 루프가 실제로 빠져나가야 false 가 된다(M-21: 예전엔 바로
  /// false 로 바꿔 돌던 작업 위에 새 동기화가 겹쳐 시작될 수 있었다).
  static bool get isRunning => _running;
  static bool _stopRequested = false;

  /// 사용자 중지 또는 DB 연결 닫기 요청(백업·복원·로그아웃 — M-25).
  static bool get _stopping => _stopRequested || LocalDbService.closeRequested;

  static final _controller = StreamController<SyncEvent>.broadcast();
  static Stream<SyncEvent> get events => _controller.stream;

  /// 마지막 sync 에서 발생한 신규/처리변경 신고 목록.
  /// 형식: {change_type, 신고번호, 신고명, 처리상태, 처리기관, 범칙금_과태료, ID, ...}
  /// fullSync 시에는 비움 (전체 재동기화는 변경 알림 의미 없음).
  static List<Map<String, dynamic>> _lastChanges = [];
  static List<Map<String, dynamic>> get lastChanges =>
      List.unmodifiable(_lastChanges);

  /// emitChanges 호출 시마다 신호 — ReportProvider 가 구독해서 카드 시트 트리거.
  static final _changesEmittedController = StreamController<void>.broadcast();
  static Stream<void> get changesEmitted => _changesEmittedController.stream;

  static const _methodChannel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );

  /// FGS ref counting — SyncEngine.start 와 drainIfPending 가 중첩 호출될 때
  /// (drain → SyncEngine.start) 한 번만 startSyncFgs / stopSyncFgs 호출되도록 관리.
  static int _fgsRefCount = 0;

  /// 동기화 작업 시작 시 호출 — 첫 호출 시 Foreground Service 가동 → 프로세스 보호.
  static Future<void> acquireFgs(String message) async {
    _fgsRefCount++;
    if (_fgsRefCount == 1) {
      try {
        await _methodChannel.invokeMethod('startSyncFgs', {'message': message});
      } catch (_) {
        // FGS 시작 실패 — 무시 (Android 12+ 백그라운드 제한 등)
      }
    }
  }

  /// 동기화 작업 종료 시 호출 — 마지막 호출 시 FGS 정지.
  static Future<void> releaseFgs() async {
    if (_fgsRefCount > 0) _fgsRefCount--;
    if (_fgsRefCount == 0) {
      try {
        await _methodChannel.invokeMethod('stopSyncFgs');
      } catch (_) {}
    }
  }

  static void _emit(SyncEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }

  static void _log(String msg) =>
      _emit(SyncEvent(type: SyncEventType.log, message: msg));

  /// 외부에서 sync 로그 emit (StandaloneAutoSyncService 개별 fetch 등).
  /// CrawlScreen 이 SyncEngine.events 를 구독하므로 동일 채널로 표시됨.
  static void emitLog(String msg) => _log(msg);

  /// 외부에서 sync 종료 신호 emit. CrawlScreen 이 받으면 _setRunning(false) 실행.
  /// drainIfPending 처럼 SyncEngine.start() 를 직접 호출하지 않는 흐름에서 사용.
  static void emitDone(String msg) {
    _emit(SyncEvent(type: SyncEventType.done, message: msg));
  }

  static Future<void> start({bool fullSync = false}) async {
    if (_running) return;
    _running = true;
    _stopRequested = false;
    _lastChanges = [];
    await acquireFgs(fullSync ? '전체 재동기화 진행 중...' : '증분 동기화 진행 중...');
    try {
      await LocalDbService.runBackgroundWork(() => _run(fullSync: fullSync));
    } catch (e) {
      ReviewPromptService.markSessionError();
      _emit(SyncEvent(type: SyncEventType.error, message: e.toString()));
    } finally {
      _running = false;
      await releaseFgs();
    }
  }

  static Future<void> _run({bool fullSync = false}) async {
    _log('동기화 시작...');

    // 전체 건수 파악
    _log('신고 건수 확인 중...');
    int totalCount;
    try {
      totalCount = await StandaloneApiService.fetchTotalCount();
    } on TokenExpiredException {
      rethrow; // 메시지가 그대로 사용자에게 가야 한다(재로그인 안내)
    } on AuthTemporarilyUnavailableException {
      rethrow; // 네트워크·점검 — '토큰 만료'로 보이지 않게 그대로 전달
    } catch (e) {
      throw Exception('목록 조회 실패: $e');
    }
    _log('총 $totalCount건 발견');

    if (totalCount == 0) {
      _log('신고 내역이 없습니다.');
      await _saveSyncTime();
      _emit(SyncEvent(type: SyncEventType.done, total: 0));
      return;
    }

    // 기존 DB 상태 스냅샷: ID → {처리상태, 종결여부}
    // 서버 _get_new_and_incomplete_ids 로직 동일:
    //   신규 OR (종결여부='N' AND title.상태 ≠ detail.처리상태)
    final existingStatus = <String, Map<String, String>>{};
    if (!fullSync) {
      // 사이트 원본 상태만(사용자 수정값 제외) — 사용자가 종결여부를 고쳐도 재조회는 사이트 기준으로 계속된다.
      final states = await LocalDbService.getSyncStates();
      for (final entry in states.entries) {
        if (entry.key.isEmpty) continue;
        existingStatus[entry.key] = {
          '처리상태': entry.value.status,
          '종결여부': entry.value.finished,
          '보완_미응답': entry.value.supplementOpen == 'Y' ? 'Y' : 'N',
        };
      }
      _log('기존 저장 ${existingStatus.length}건, 신규/변경 확인 시작');
    } else {
      // 먼저 지우지 않는다(M-1): 모든 신고를 다시 받아 제자리 갱신하고, 사용자 데이터(수정값·감시목록·중복 판단·지오코딩 캐시)는 둔다.
      _log('전체 재동기화 모드 (모든 신고를 다시 받음, 사용자 데이터 유지)');
    }

    // 목록 페이지 순회 (200건씩)
    final allItems = <Map<String, dynamic>>[];
    var listPageErrors = 0;
    int start = 1;
    const pageSize = 200;

    while (start <= totalCount) {
      if (_stopping) {
        listPageErrors++; // 목록을 다 받지 못함 → 정리·동기화 시각 기록 안 함
        _log('중지 요청 — 목록 조회를 멈춤');
        break;
      }
      final end = (start + pageSize - 1).clamp(1, totalCount);
      _log('목록 $start~$end건 조회 중...');
      try {
        final data = await StandaloneApiService.fetchReportList(
          startRow: start,
          endRow: end,
        );
        final list = (data['result'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        allItems.addAll(list);
      } on TokenExpiredException {
        rethrow;
      } on AuthTemporarilyUnavailableException {
        rethrow;
      } catch (e) {
        listPageErrors++;
        _log('[오류] 목록 조회 실패: $e');
      }
      start += pageSize;
    }

    // 목록 값 갱신(서버 title_to_sql 과 같음): 상세를 다시 받지 않는 종결 신고의 상태·만족도도 사이트와 맞춘다.
    if (allItems.isNotEmpty && !_stopping) {
      final refreshed = await LocalDbService.updateTitlesFromList(allItems);
      if (refreshed > 0) _log('목록 값 갱신: $refreshed건');
    }

    // 신규/증분 대상 필터 (서버 get_pending_detail_ids 동일)
    // - 신규: DB에 없는 ID
    // - 미종결: 종결여부 != 'Y'
    // - 열린 보완: 보완_미응답 = 'Y'
    final toSync = fullSync
        ? allItems
        : allItems.where((item) {
            final cNo = item['C_NO']?.toString() ?? '';
            final snap = existingStatus[cNo];
            if (snap == null) return true; // 신규
            if (snap['보완_미응답'] == 'Y') return true;
            return snap['종결여부'] != 'Y';
          }).toList();

    _log('상세 조회 대상: ${toSync.length}건');

    int done = 0;
    int errors = 0;

    for (final item in toSync) {
      if (_stopping) {
        _log('중지 요청 — 상세 조회를 멈춤 ($done/${toSync.length}건 저장됨)');
        break;
      }
      final cNo = item['C_NO']?.toString() ?? '';
      if (cNo.isEmpty) continue;

      _emit(
        SyncEvent(
          type: SyncEventType.progress,
          message: '상세 조회 중... ($cNo)',
          current: done,
          total: toSync.length,
        ),
      );

      try {
        final detail = await StandaloneApiService.fetchReportDetail(cNo);
        var report = parseJsonToReport(item, detail);
        final ev = entryValueFromDetail(item, detail);
        final cat = categoryFromEntryValue(ev);
        // 본문 원문(서버와 같은 정규화) — 중복 해시·변경 판정이 서버와 같아진다
        final raw = normalizeRawPayloadText(rawContentOf(detail));

        // 별점이 있는 신고 한정으로 사유 추가 fetch (인증 불필요 별도 API)
        final augmented = await _augmentRatingCause(report);
        report = augmented.report;
        // 주정차 사진 촬영 시각(서버 상세 저장과 같은 시점·규칙)
        final photo = await MaintenanceService.prefetchForSave(
          report.id,
          cat,
          ev,
          report.attachedPhotos,
        );

        await LocalDbService.upsertReport(
          report,
          cat,
          ev,
          rawContent: raw,
          ratingLookup: augmented.lookup,
          photoCapture: photo,
        );
        if (!fullSync) _trackChange(existingStatus[cNo], report);
        done++;

        if (done % 10 == 0) {
          _log('$done/${toSync.length}건 완료');
        }
      } on TokenExpiredException {
        // API 계층이 이미 자동 재로그인을 해 봤고 실패했다(비밀번호 거부·로그인 정보 없음) — 동기화를 멈추고 안내.
        rethrow;
      } on AuthTemporarilyUnavailableException {
        // 네트워크·점검 — 남은 건도 같은 이유로 실패하므로 멈춘다. '토큰 만료'로 안내하지 않는다.
        rethrow;
      } catch (e) {
        errors++;
        _log('[오류] $cNo: $e');
      }

      // API 과부하 방지: 100ms 딜레이
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (!_stopping) {
      // 종결돼 다시 받지 않는 주정차 신고의 촬영 시각 재시도(서버 크롤링 끝 backfill_missing 과 같음)
      final filled = await MaintenanceService.backfillMissing();
      if (filled > 0) _log('[photo] 촬영 시각 재시도로 $filled건 채움');
    }

    final duplicateRefresh =
        await DuplicateProjectionService.refreshDuplicateGroups(
          await LocalDbService.db,
          trackChanges: !fullSync,
        );
    if (!fullSync) {
      final duplicateChanges =
          (duplicateRefresh['changes'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
      if (duplicateChanges.isNotEmpty) {
        _lastChanges = [..._lastChanges, ...duplicateChanges];
      }
    }

    // 사이트 목록에서 사라진 신고 정리는 전체 재동기화이고 목록을 빠짐없이 받았을 때만(M-1, M-20).
    if (fullSync && !_stopping && listPageErrors == 0 && allItems.isNotEmpty) {
      final removed = await LocalDbService.removeReportsNotIn(
        allItems
            .map((i) => i['C_NO']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet(),
      );
      if (removed > 0) _log('사이트 목록에 없는 신고 $removed건 정리');
    }
    // 목록 페이지가 하나라도 실패하면 마지막 동기화 시각을 성공으로 남기지 않는다(M-20).
    if (_stopping) {
      _log('[주의] 중지됨 — 마지막 동기화 시각을 갱신하지 않음');
    } else if (listPageErrors == 0) {
      await _saveSyncTime();
    } else {
      _log('[주의] 목록 $listPageErrors페이지 실패 — 마지막 동기화 시각을 갱신하지 않음');
    }

    if (_lastChanges.isNotEmpty) {
      await emitChanges(_lastChanges);
    }

    final msg =
        '${_stopping ? '동기화 중지' : '동기화 완료'}: $done건 저장${errors > 0 ? ', $errors건 오류' : ''}';
    _log(msg);
    _emit(
      SyncEvent(
        type: SyncEventType.done,
        message: msg,
        current: done,
        total: toSync.length,
      ),
    );
  }

  /// 신규/처리변경 신고 emit:
  ///   1. flutter.pending_crawl_changes SharedPref 에 누적 (main.dart 카드 시트 트리거)
  ///   2. 각 신고에 대한 개별 heads-up 알림 (MainActivity.showNotification)
  ///   3. changesEmitted Stream 신호 → ReportProvider 가 nonce 갱신
  static Future<void> emitChanges(List<Map<String, dynamic>> changes) async {
    if (changes.isEmpty) return;

    // 기존 pending 데이터에 누적 (main.dart 가 처리 전이면 함께 노출)
    await PendingChangesStore.append(changes);

    for (final r in changes) {
      final notificationKind = r['notification_kind']?.toString() ?? 'report';
      if (notificationKind == 'duplicate') {
        final title = r['title']?.toString() ?? '🧩 중복 신고 변경';
        final body = r['body']?.toString() ?? '';
        try {
          await _methodChannel.invokeMethod('showNotification', {
            'title': title,
            'body': body,
            'nav_tab': 4,
            'nav_subtab': 1,
            'event_type': 'crawl_changes',
            'payload_json': jsonEncode(r),
          });
        } catch (_) {}
        continue;
      }

      final changeType = r['change_type']?.toString() ?? '';
      final name = (r['신고명'] ?? '신고').toString();
      final reportNo = (r['신고번호'] ?? '').toString();
      final status = (r['처리상태'] ?? '').toString();
      final agency = (r['처리기관'] ?? '').toString();
      final fine = (r['범칙금_과태료'] ?? '').toString();

      final lines = <String>[];
      if (reportNo.isNotEmpty) lines.add('신고번호: $reportNo');
      if (status.isNotEmpty) lines.add('처리상태: $status');
      if (agency.isNotEmpty) lines.add('처리기관: $agency');
      if (fine.isNotEmpty && fine != 'null' && fine != '미확인') {
        lines.add('범칙금/과태료: $fine');
      }
      final title = switch (changeType) {
        ChangeType.newReport => '🆕 신규 신고 — $name',
        ChangeType.individualConfirm => '✅ 개별 동기화 — $name',
        _ => '🔄 처리 변경 — $name',
      };
      try {
        await _methodChannel.invokeMethod('showNotification', {
          'title': title,
          'body': lines.join('\n'),
          'nav_tab': 4,
          'nav_subtab': 1,
          'event_type': 'crawl_changes',
          'payload_json': jsonEncode(r),
        });
      } catch (_) {
        // MainActivity 미준비 등 — 무시
      }
    }

    if (!_changesEmittedController.isClosed) {
      _changesEmittedController.add(null);
    }
  }

  /// snapshot 과 비교해 신규/처리변경 판정 후 _lastChanges 에 추가.
  static void _trackChange(Map<String, String>? snap, Report r) {
    if (snap == null) {
      _lastChanges.add(reportToChangeMap(r, ChangeType.newReport));
    } else if (snap['처리상태'] != r.status) {
      _lastChanges.add(reportToChangeMap(r, ChangeType.statusChanged));
    }
  }

  /// Report 객체를 Report.fromJson 키 형식의 Map 으로 변환 + change_type 부여.
  /// pending_crawl_changes / notification history / bottom sheet 에서 공통 사용.
  static Map<String, dynamic> reportToChangeMap(Report r, String changeType) {
    return {
      'change_type': changeType,
      'ID': r.id,
      '신고번호': r.reportNumber,
      '신고명': r.name,
      '신고일': r.date,
      '답변일': r.responseDate,
      '처리기관': r.agency,
      '담당자': r.manager,
      '처리상태': r.status,
      '범칙금_과태료': r.fineInfo,
      '벌점': r.penaltyPoints,
      '차량번호': r.carNumber,
      '위반법규': r.law,
      '위반장소': r.location,
      '발생일자': r.occurrenceDate,
      '발생시각': r.occurrenceTime,
      '신고내용': r.reportContent,
      '처리내용': r.processContent,
      '첨부사진': r.attachedPhotos,
      '첨부파일': r.attachedFiles,
      '지도': r.mapImage,
      '만족도조사여부': r.pollStatus,
      '종결여부': r.processingFinish,
      'category': r.category,
      'synced_at': r.syncedAt,
    };
  }

  /// 별점이 부여된 신고에 한해 별점사유를 추가 fetch.
  /// 안전신문고 만족도 조회는 로그인 ID가 아니라 휴대폰번호가 필요하다.
  /// fetch 실패해도 별점 자체는 보존, ratingCause만 빈 채로 남김.
  /// (auto_sync_service에서도 호출 → public)
  static Future<({Report report, RatingLookup lookup})> augmentRatingCause(
    Report report,
  ) => _augmentRatingCause(report);

  static Future<({Report report, RatingLookup lookup})> _augmentRatingCause(
    Report report,
  ) async {
    if (report.rating == null || report.rating! <= 0) {
      return (report: report, lookup: RatingLookup.notTried);
    }
    final prefs = await SharedPreferences.getInstance();
    final phone = (prefs.getString(AppPrefsKeys.standalonePhoneNumber) ?? '')
        .replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.isEmpty) return (report: report, lookup: RatingLookup.failed);
    final result = await StandaloneApiService.fetchSatisfaction(
      report.reportNumber,
      phone,
    );
    if (result.score == null) {
      return (
        report: report,
        lookup: result.confirmed
            ? RatingLookup.confirmedNone
            : RatingLookup.failed,
      );
    }
    return (
      report: report.copyWith(
        rating: result.score! > 0 ? result.score : report.rating,
        ratingCause: result.cause,
      ),
      lookup: RatingLookup.found,
    );
  }

  static Future<void> _saveSyncTime() async {
    // 원천은 DB 의 last_sync 하나(M-19: 아무도 안 읽던 설정 사본은 없앰).
    await LocalDbService.setMeta('last_sync', DateTime.now().toIso8601String());
  }

  static Future<String?> getLastSyncTime() async {
    return LocalDbService.getMeta('last_sync');
  }

  /// 멈춤을 요청한다. 진행 중인 요청 하나가 끝나면 루프가 빠져나가고, 그때 [isRunning] 이 false 가 된다.
  static void stop() {
    if (_running) _stopRequested = true;
  }
}
