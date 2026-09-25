import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/app_mode.dart';
import '../models/rating_batch_result.dart';
import '../models/report.dart';
import 'api_service.dart';
import 'local_db_service.dart';
import 'standalone_api_service.dart';
import 'sync_engine.dart';

class RatingService {
  static const _blockedStatuses = {'취하', '답변 대기', '처리중'};

  /// 공통 사유 안전 상한(유니코드 코드포인트 수). 서버 `rating_eligibility.RATING_CAUSE_MAX` 와 같다.
  static const ratingCauseMax = 1000;

  /// 서버 `_TRIM_CHARS`·JS `trim()` 과 같은 문자(공백·탭·줄바꿈·NBSP·전각 공백·BOM 등).
  static const _causeTrimChars = <int>{
    0x20, 0x09, 0x0A, 0x0B, 0x0C, 0xA0, 0x1680, //
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008,
    0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
  };

  /// 줄바꿈을 \n 으로 맞추고 앞뒤 공백을 뗀다(가운데 줄바꿈 유지). 서버 `normalize_cause` 와 같다.
  static String normalizeCause(String? text) {
    final runes = (text ?? '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .runes
        .toList();
    var start = 0;
    var end = runes.length;
    while (start < end && _causeTrimChars.contains(runes[start])) {
      start++;
    }
    while (end > start && _causeTrimChars.contains(runes[end - 1])) {
      end--;
    }
    return String.fromCharCodes(runes.sublist(start, end));
  }

  /// 정리한 사유가 상한을 넘으면 안내 문구. 서버 `cause_error` 와 같은 문구.
  static String? causeError(String? text) {
    final length = normalizeCause(text).runes.length;
    return length > ratingCauseMax
        ? '사유는 $ratingCauseMax자까지 입력할 수 있습니다. (현재 $length자)'
        : null;
  }

  static Future<RatingBatchResult> submit({
    required AppMode appMode,
    required List<Report> selectedReports,
    required int score,
    String cause = '',
    ApiService? api,
    required bool isStandaloneDemo,
  }) async {
    final timestamp = _timestamp();
    cause = normalizeCause(cause);
    final causeProblem = causeError(cause);
    if (causeProblem != null) throw ArgumentError(causeProblem);
    final uniqueReports = _dedupReports(selectedReports);
    final skippedItems = <RatingBatchItem>[];
    final eligibleReports = <Report>[];

    for (final report in uniqueReports) {
      final reason = ineligibleReason(report);
      if (reason != null) {
        skippedItems.add(_skipItem(report, reason));
      } else {
        eligibleReports.add(report);
      }
    }

    if (isStandaloneDemo) {
      final failed = uniqueReports
          .map((report) => _failureItem(report, '데모 모드에서는 별점 주기를 실행할 수 없습니다.'))
          .toList(growable: false);
      return _buildResult(
        timestamp: timestamp,
        appMode: appMode,
        score: score,
        requested: uniqueReports.length,
        eligible: 0,
        items: failed,
      );
    }

    if (eligibleReports.isEmpty) {
      return _buildResult(
        timestamp: timestamp,
        appMode: appMode,
        score: score,
        requested: uniqueReports.length,
        eligible: 0,
        items: skippedItems,
      );
    }

    final remoteItems = appMode == AppMode.standalone
        ? await _submitStandalone(eligibleReports, score, cause)
        : await _submitServer(
            api: api,
            eligibleReports: eligibleReports,
            score: score,
            cause: cause,
          );

    return _buildResult(
      timestamp: timestamp,
      appMode: appMode,
      score: score,
      requested: uniqueReports.length,
      eligible: eligibleReports.length,
      items: [...skippedItems, ...remoteItems],
    );
  }

  static String? ineligibleReason(Report report) {
    final pollStatus = report.pollStatus.trim();
    final status = _canonicalStatus(report.status);

    if (pollStatus == '참여 완료') return '이미 만족도 조사에 참여한 신고입니다.';
    if (pollStatus == '참여 불가') return '만족도 조사가 불가능한 신고입니다.';
    if (_blockedStatuses.contains(status)) {
      return '$status 상태에서는 만족도 조사를 진행할 수 없습니다.';
    }
    return null;
  }

  static bool isListEligible(Report report) {
    final pollStatus = report.pollStatus.trim();
    if (pollStatus == '참여 완료' || pollStatus == '참여 불가') return false;
    final status = _canonicalStatus(report.status);
    return !_blockedStatuses.contains(status);
  }

  /// 한 신고의 제출 시도 횟수(서버 `max_retry_attemps + 1` 과 같은 역할). 제출 뒤 사이트에서 점수가 아직 안 보이면 다시 확인한다.
  static const _standaloneAttempts = 3;

  /// Standalone 제출 — 서버 `star_rating_service.run_batch_rating` 과 같은 흐름:
  /// 사이트 확인 → (점수 있으면: 이번에 제출했으면 성공, 아니면 스킵) → 제출 → 다시 확인해 점수가 보일 때만 성공.
  /// 저장은 사이트가 돌려준 점수·사유. 테스트는 [lookup]·[post] 로 사이트를 바꿔 끼운다.
  static Future<List<RatingBatchItem>> _submitStandalone(
    List<Report> reports,
    int score,
    String cause, {
    Future<({int? score, String cause, bool confirmed})> Function(String spp)?
    lookup,
    Future<void> Function(String spp, int score, String cause)? post,
    Duration retryDelay = const Duration(seconds: 1),
    Duration pause = const Duration(seconds: 1),
  }) async {
    final fetch = lookup ?? StandaloneApiService.fetchSatisfactionStatus;
    final send =
        post ??
        (String spp, int s, String c) =>
            StandaloneApiService.submitSatisfaction(spp, score: s, cause: c);
    final results = <RatingBatchItem>[];
    await SyncEngine.acquireFgs('별점 주기 진행 중...');
    try {
      if (lookup == null) await StandaloneApiService.warmUpSatisfaction();
      for (final report in reports) {
        final reportNumber = report.reportNumber;
        var posted = false;
        RatingBatchItem? outcome;
        Object? lastError;
        for (var attempt = 0; attempt < _standaloneAttempts; attempt++) {
          if (attempt > 0) await Future<void>.delayed(retryDelay);
          try {
            final site = await fetch(reportNumber);
            if (!site.confirmed) throw Exception('만족도 조회 실패');
            if (site.score != null && site.score! > 0) {
              await _saveSiteRating(reportNumber, site);
              outcome = posted
                  ? _successItem(report, site, cause)
                  : _skipItem(report, '이미 만족도 조사에 참여한 신고입니다.');
              break;
            }
            await send(reportNumber, score, cause);
            posted = true;
            // HTTP 200 만으로는 성공으로 보지 않는다 — 사이트에서 점수를 다시 읽어 확인
            final verify = await fetch(reportNumber);
            if (verify.confirmed && verify.score != null && verify.score! > 0) {
              await _saveSiteRating(reportNumber, verify);
              outcome = _successItem(report, verify, cause);
              break;
            }
            throw Exception('제출 후 사이트에서 점수를 확인하지 못했습니다');
          } catch (e) {
            lastError = e;
          }
        }
        results.add(outcome ?? _failureItem(report, '$lastError'));
        if (pause > Duration.zero) await Future<void>.delayed(pause);
      }
    } finally {
      await SyncEngine.releaseFgs();
    }
    return results;
  }

  static Future<void> _saveSiteRating(
    String reportNumber,
    ({int? score, String cause, bool confirmed}) site,
  ) => LocalDbService.updateReportRatingByNumber(
    reportNumber,
    pollStatus: '참여 완료',
    rating: site.score,
    ratingCause: site.cause,
  );

  static RatingBatchItem _successItem(
    Report report,
    ({int? score, String cause, bool confirmed}) site,
    String cause,
  ) {
    final mismatch = cause.isNotEmpty && normalizeCause(site.cause) != cause;
    return RatingBatchItem(
      reportNumber: report.reportNumber,
      name: report.name,
      status: RatingBatchItemStatus.success,
      message:
          '${site.score}점 별점을 전송했습니다.${mismatch ? ' (사이트에 저장된 사유가 보낸 사유와 다릅니다)' : ''}',
      reportData: reportToMap(report),
    );
  }

  @visibleForTesting
  static Future<List<RatingBatchItem>> submitStandaloneForTest(
    List<Report> reports,
    int score,
    String cause, {
    required Future<({int? score, String cause, bool confirmed})> Function(
      String spp,
    )
    lookup,
    required Future<void> Function(String spp, int score, String cause) post,
  }) => _submitStandalone(
    reports,
    score,
    normalizeCause(cause),
    lookup: lookup,
    post: post,
    retryDelay: Duration.zero,
    pause: Duration.zero,
  );

  static Future<List<RatingBatchItem>> _submitServer({
    required ApiService? api,
    required List<Report> eligibleReports,
    required int score,
    String cause = '',
  }) async {
    if (api == null) {
      return eligibleReports
          .map((report) => _failureItem(report, '서버 연결 정보가 없습니다.'))
          .toList(growable: false);
    }

    await SyncEngine.acquireFgs('서버 별점 주기 상태 확인 중...');
    try {
      final start = await api.startRatingBatch(
        reportNumbers: eligibleReports
            .map((report) => report.reportNumber)
            .toList(),
        score: score,
        cause: cause,
      );
      if (start.$1 == false) {
        return eligibleReports
            .map((report) => _failureItem(report, start.$2))
            .toList(growable: false);
      }

      String? lastLog;
      Object? lastError;
      for (var i = 0; i < 600; i++) {
        try {
          lastLog = await api.fetchCurrentRatingLog();
          final parsed = _parseServerLog(lastLog ?? '');
          if (parsed.isComplete) {
            return _buildServerItems(
              eligibleReports: eligibleReports,
              parsed: parsed,
            );
          }
        } catch (e) {
          lastError = e;
        }
        await Future.delayed(const Duration(seconds: 2));
      }

      final parsed = _parseServerLog(lastLog ?? '');
      return _buildServerItems(
        eligibleReports: eligibleReports,
        parsed: parsed,
        fallbackMessage: lastError == null
            ? '서버 별점 작업 완료를 제한 시간 안에 확인하지 못했습니다.'
            : '서버 별점 작업 완료를 확인하지 못했습니다: $lastError',
      );
    } finally {
      await SyncEngine.releaseFgs();
    }
  }

  static List<RatingBatchItem> _buildServerItems({
    required List<Report> eligibleReports,
    required _ParsedRatingLog parsed,
    String? fallbackMessage,
  }) {
    return eligibleReports
        .map((report) {
          final entry = parsed.byReport[report.reportNumber];
          if (entry != null) {
            return RatingBatchItem(
              reportNumber: report.reportNumber,
              name: report.name,
              status: entry.$1,
              message: entry.$2,
              reportData: reportToMap(report),
            );
          }
          return RatingBatchItem(
            reportNumber: report.reportNumber,
            name: report.name,
            status: RatingBatchItemStatus.failure,
            message: fallbackMessage ?? '서버 로그에서 결과를 확인하지 못했습니다.',
            reportData: reportToMap(report),
          );
        })
        .toList(growable: false);
  }

  static _ParsedRatingLog _parseServerLog(String log) {
    final lines = const LineSplitter().convert(log);
    final byReport = <String, (RatingBatchItemStatus, String)>{};
    var isComplete = false;

    final successExp = RegExp(r'\[(SPP-.+?)\]\s+\d+점 별점 부여 성공');
    final skipExp = RegExp(r'스킵:\s+\[(SPP-.+?)\]\s+(.+)$');
    final failExp = RegExp(r'실패:\s+\[(SPP-.+?)\]\s+(.+)$');
    final finalFailExp = RegExp(r'최종 실패:\s+\[(SPP-.+?)\]\s+오류 발생:\s*(.+)$');
    final finalSummaryExp = RegExp(
      r'성공:\s*(\d+),\s*스킵:\s*(\d+),\s*실패:\s*(\d+)',
    );

    for (final line in lines) {
      final successMatch = successExp.firstMatch(line);
      if (successMatch != null) {
        final reportNumber = successMatch.group(1)?.trim() ?? '';
        if (reportNumber.isNotEmpty) {
          byReport[reportNumber] = (
            RatingBatchItemStatus.success,
            line.contains('(API)') ? '별점 전송이 완료되었습니다.' : line.trim(),
          );
        }
        continue;
      }

      final skipMatch = skipExp.firstMatch(line);
      if (skipMatch != null) {
        final reportNumber = skipMatch.group(1)?.trim() ?? '';
        final message = skipMatch.group(2)?.trim() ?? '이미 참여한 신고입니다.';
        if (reportNumber.isNotEmpty) {
          byReport[reportNumber] = (RatingBatchItemStatus.skip, message);
        }
        continue;
      }

      final failMatch =
          finalFailExp.firstMatch(line) ?? failExp.firstMatch(line);
      if (failMatch != null) {
        final reportNumber = failMatch.group(1)?.trim() ?? '';
        final message = failMatch.group(2)?.trim() ?? '별점 전송에 실패했습니다.';
        if (reportNumber.isNotEmpty) {
          byReport[reportNumber] = (RatingBatchItemStatus.failure, message);
        }
        continue;
      }

      if (finalSummaryExp.hasMatch(line)) {
        isComplete = true;
      }
    }

    return _ParsedRatingLog(isComplete: isComplete, byReport: byReport);
  }

  static RatingBatchResult _buildResult({
    required String timestamp,
    required AppMode appMode,
    required int score,
    required int requested,
    required int eligible,
    required List<RatingBatchItem> items,
  }) {
    return RatingBatchResult(
      id: 'rating_${DateTime.now().millisecondsSinceEpoch}',
      timestamp: timestamp,
      mode: appMode == AppMode.standalone ? 'standalone' : 'server',
      score: score,
      requestedCount: requested,
      eligibleCount: eligible,
      items: items,
    );
  }

  static RatingBatchItem _skipItem(Report report, String message) {
    return RatingBatchItem(
      reportNumber: report.reportNumber,
      name: report.name,
      status: RatingBatchItemStatus.skip,
      message: message,
      reportData: reportToMap(report),
    );
  }

  static RatingBatchItem _failureItem(Report report, String message) {
    return RatingBatchItem(
      reportNumber: report.reportNumber,
      name: report.name,
      status: RatingBatchItemStatus.failure,
      message: message,
      reportData: reportToMap(report),
    );
  }

  static List<Report> _dedupReports(List<Report> reports) {
    final seen = <String>{};
    final deduped = <Report>[];
    for (final report in reports) {
      if (!seen.add(report.reportNumber)) continue;
      deduped.add(report);
    }
    return deduped;
  }

  static String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  static String _canonicalStatus(String status) {
    final trimmed = status.trim();
    if (trimmed == '진행' ||
        trimmed == '진행중' ||
        trimmed == '검토중' ||
        trimmed == '처리중') {
      return '처리중';
    }
    return trimmed;
  }
}

class _ParsedRatingLog {
  final bool isComplete;
  final Map<String, (RatingBatchItemStatus, String)> byReport;

  const _ParsedRatingLog({required this.isComplete, required this.byReport});
}
