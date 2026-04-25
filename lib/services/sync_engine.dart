import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/report.dart';
import 'local_db_service.dart';
import 'standalone_api_service.dart';
import 'standalone_auth_service.dart';
import 'standalone_parser.dart';

/// 동기화 이벤트 타입
enum SyncEventType { log, progress, done, error }

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
  static bool get isRunning => _running;

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

  static const _methodChannel =
      MethodChannel('com.fentanest.mysafetyreport/permissions');

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
    _lastChanges = [];
    await acquireFgs(fullSync ? '전체 재동기화 진행 중...' : '증분 동기화 진행 중...');
    try {
      await _run(fullSync: fullSync);
    } catch (e) {
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
      final reports = await LocalDbService.getAllReports();
      for (final r in reports) {
        if (r.id.isNotEmpty) {
          existingStatus[r.id] = {'처리상태': r.status, '종결여부': r.processingFinish};
        }
      }
      _log('기존 저장 ${existingStatus.length}건, 신규/변경 확인 시작');
    } else {
      _log('전체 재동기화 모드');
      await LocalDbService.clearAll();
    }

    // 목록 페이지 순회 (200건씩)
    final allItems = <Map<String, dynamic>>[];
    int start = 1;
    const pageSize = 200;

    while (start <= totalCount) {
      final end = (start + pageSize - 1).clamp(1, totalCount);
      _log('목록 ${start}~${end}건 조회 중...');
      try {
        final data = await StandaloneApiService.fetchReportList(
          startRow: start,
          endRow: end,
        );
        final list = (data['result'] as List? ?? []).cast<Map<String, dynamic>>();
        allItems.addAll(list);
      } catch (e) {
        _log('[오류] 목록 조회 실패: $e');
      }
      start += pageSize;
    }

    // 신규/변경 항목 필터 (서버 _get_new_and_incomplete_ids 동일 로직)
    // - 신규: DB에 없는 ID
    // - 변경: 종결여부='N' AND 목록의 C_NOW 상태가 DB 상태와 다름
    final _cNowStatus = <int, String>{
      0: '진행', 10: '답변완료', 11: '일부수용', 12: '검토중',
      14: '불수용', 15: '기타', 20: '취하', 30: '이송',
    };
    final toSync = fullSync
        ? allItems
        : allItems.where((item) {
            final cNo = item['C_NO']?.toString() ?? '';
            final snap = existingStatus[cNo];
            if (snap == null) return true; // 신규
            if (snap['종결여부'] == 'Y') return false; // 종결 완료 → 스킵
            // 목록의 C_NOW 매핑 상태와 DB의 담당자 처리상태 비교 (서버 동일)
            int cNow = 0;
            try { cNow = (item['C_NOW'] as num?)?.toInt() ?? 0; } catch (_) {}
            final listStatus = _cNowStatus[cNow] ?? '진행';
            return listStatus != snap['처리상태'];
          }).toList();

    _log('상세 조회 대상: ${toSync.length}건');

    int done = 0;
    int errors = 0;

    for (final item in toSync) {
      final cNo = item['C_NO']?.toString() ?? '';
      if (cNo.isEmpty) continue;

      _emit(SyncEvent(
        type: SyncEventType.progress,
        message: '상세 조회 중... ($cNo)',
        current: done,
        total: toSync.length,
      ));

      try {
        final detail = await StandaloneApiService.fetchReportDetail(cNo);
        final report = parseJsonToReport(item, detail);
        final ev = entryValueFromDetail(item, detail);
        final cat = categoryFromEntryValue(ev);
        // 차량번호 파싱 실패 디버깅용: API 원본 C_A_CONTENTS 저장
        final raw = (detail['C_A_CONTENTS'] ?? detail['C_A_BODY'] ?? '').toString();

        await LocalDbService.upsertReport(report, cat, ev, rawContent: raw);
        if (!fullSync) _trackChange(existingStatus[cNo], report);
        done++;

        if (done % 10 == 0) {
          _log('$done/${toSync.length}건 완료');
        }
      } on TokenExpiredException {
        // 토큰 만료 → 자동 재로그인 시도
        _log('토큰 만료 감지, 자동 재로그인 시도 중...');
        final newToken = await StandaloneAuthService.tryAutoRelogin();
        if (newToken == null) {
          throw Exception('토큰 만료. 설정 > 재로그인 후 다시 시도해주세요.');
        }
        _log('자동 재로그인 성공, 상세 조회 재시도 중...');
        // 재시도 1회
        try {
          final detail = await StandaloneApiService.fetchReportDetail(cNo);
          final report = parseJsonToReport(item, detail);
          final ev = entryValueFromDetail(item, detail);
          final cat = categoryFromEntryValue(ev);
          final raw = (detail['C_A_CONTENTS'] ?? detail['C_A_BODY'] ?? '').toString();
          await LocalDbService.upsertReport(report, cat, ev, rawContent: raw);
          if (!fullSync) _trackChange(existingStatus[cNo], report);
          done++;
        } catch (retryErr) {
          errors++;
          _log('[오류] $cNo 재시도 실패: $retryErr');
        }
      } catch (e) {
        errors++;
        _log('[오류] $cNo: $e');
      }

      // API 과부하 방지: 100ms 딜레이
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await _saveSyncTime();

    if (_lastChanges.isNotEmpty) {
      await emitChanges(_lastChanges);
    }

    final msg = '동기화 완료: ${done}건 저장'
        '${errors > 0 ? ', $errors건 오류' : ''}';
    _log(msg);
    _emit(SyncEvent(
      type: SyncEventType.done,
      message: msg,
      current: done,
      total: toSync.length,
    ));
  }

  /// 신규/처리변경 신고 emit:
  ///   1. flutter.pending_crawl_changes SharedPref 에 누적 (main.dart 카드 시트 트리거)
  ///   2. 각 신고에 대한 개별 heads-up 알림 (MainActivity.showNotification)
  ///   3. changesEmitted Stream 신호 → ReportProvider 가 nonce 갱신
  static Future<void> emitChanges(List<Map<String, dynamic>> changes) async {
    if (changes.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    // 기존 pending 데이터에 누적 (main.dart 가 처리 전이면 함께 노출)
    final existingRaw = prefs.getString('pending_crawl_changes');
    List<dynamic> existing = const [];
    if (existingRaw != null && existingRaw.isNotEmpty) {
      try {
        existing = jsonDecode(existingRaw) as List<dynamic>;
      } catch (_) {}
    }
    await prefs.setString(
      'pending_crawl_changes',
      jsonEncode([...existing, ...changes]),
    );

    for (final r in changes) {
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
        '신규' => '🆕 신규 신고 — $name',
        '개별확인' => '✅ 개별 동기화 — $name',
        _ => '🔄 처리 변경 — $name',
      };
      try {
        await _methodChannel.invokeMethod('showNotification', {
          'title': title,
          'body': lines.join('\n'),
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
      _lastChanges.add(reportToChangeMap(r, '신규'));
    } else if (snap['처리상태'] != r.status) {
      _lastChanges.add(reportToChangeMap(r, '처리변경'));
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
    };
  }

  static Future<void> _saveSyncTime() async {
    final now = DateTime.now().toIso8601String();
    await LocalDbService.setMeta('last_sync', now);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('standaloneSyncTime', now);
  }

  static Future<String?> getLastSyncTime() async {
    return LocalDbService.getMeta('last_sync');
  }

  static void stop() {
    _running = false;
  }
}
