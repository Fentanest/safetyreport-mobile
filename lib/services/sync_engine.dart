import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

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

  static void _emit(SyncEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }

  static void _log(String msg) =>
      _emit(SyncEvent(type: SyncEventType.log, message: msg));

  static Future<void> start({bool fullSync = false}) async {
    if (_running) return;
    _running = true;
    try {
      await _run(fullSync: fullSync);
    } catch (e) {
      _emit(SyncEvent(type: SyncEventType.error, message: e.toString()));
    } finally {
      _running = false;
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

    // 기존 DB의 c_no 목록
    final existing = <String>{};
    if (!fullSync) {
      final reports = await LocalDbService.getAllReports();
      for (final r in reports) {
        if (r.id.isNotEmpty) existing.add(r.id);
      }
      _log('기존 저장 ${existing.length}건, 신규 확인 시작');
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

    // 신규/변경 항목 필터
    final toSync = fullSync
        ? allItems
        : allItems.where((item) {
            final cNo = item['C_NO']?.toString() ?? '';
            return !existing.contains(cNo);
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

        await LocalDbService.upsertReport(report, cat, ev);
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
          await LocalDbService.upsertReport(report, cat, ev);
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
