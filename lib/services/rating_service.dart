import 'dart:async';
import 'dart:convert';

import '../models/app_mode.dart';
import '../models/rating_batch_result.dart';
import '../models/report.dart';
import 'api_service.dart';
import 'local_db_service.dart';
import 'standalone_api_service.dart';
import 'sync_engine.dart';

class RatingService {
  static const _terminalStatuses = {'취하', '답변 대기', '처리중', '진행', '진행중'};

  static Future<RatingBatchResult> submit({
    required AppMode appMode,
    required List<Report> selectedReports,
    required int score,
    ApiService? api,
    required bool isStandaloneDemo,
  }) async {
    final timestamp = _timestamp();
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
        ? await _submitStandalone(eligibleReports, score)
        : await _submitServer(
            api: api,
            eligibleReports: eligibleReports,
            score: score,
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
    final status = report.status.trim();

    if (pollStatus == '참여 완료') return '이미 만족도 조사에 참여한 신고입니다.';
    if (pollStatus == '참여 불가') return '만족도 조사가 불가능한 신고입니다.';
    if (pollStatus == '답변 대기') return '답변 대기 상태라 아직 만족도 조사를 할 수 없습니다.';
    if (_terminalStatuses.contains(status)) {
      return '$status 상태에서는 만족도 조사를 진행할 수 없습니다.';
    }
    return null;
  }

  static Future<List<RatingBatchItem>> _submitStandalone(
    List<Report> reports,
    int score,
  ) async {
    final results = <RatingBatchItem>[];
    await SyncEngine.acquireFgs('별점 주기 진행 중...');
    try {
      await StandaloneApiService.warmUpSatisfaction();
      for (final report in reports) {
        final reportNumber = report.reportNumber;
        try {
          final existing = await StandaloneApiService.fetchSatisfactionStatus(
            reportNumber,
          );
          if (existing.score != null && existing.score! > 0) {
            await LocalDbService.updateReportRatingByNumber(
              reportNumber,
              pollStatus: '참여 완료',
              rating: existing.score,
              ratingCause: existing.cause,
            );
            results.add(_skipItem(report, '이미 만족도 조사에 참여한 신고입니다.'));
          } else {
            await StandaloneApiService.submitSatisfaction(
              reportNumber,
              score: score,
            );
            await LocalDbService.updateReportRatingByNumber(
              reportNumber,
              pollStatus: '참여 완료',
              rating: score,
              ratingCause: '',
            );
            results.add(
              RatingBatchItem(
                reportNumber: reportNumber,
                name: report.name,
                status: RatingBatchItemStatus.success,
                message: '$score점 별점을 전송했습니다.',
                reportData: reportToMap(report),
              ),
            );
          }
        } catch (e) {
          results.add(_failureItem(report, e.toString()));
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    } finally {
      await SyncEngine.releaseFgs();
    }
    return results;
  }

  static Future<List<RatingBatchItem>> _submitServer({
    required ApiService? api,
    required List<Report> eligibleReports,
    required int score,
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

    final successExp = RegExp(r'\[(.+?)\]\s+\d+점 별점 부여 성공');
    final skipExp = RegExp(r'스킵:\s+\[(.+?)\]\s+(.+)$');
    final failExp = RegExp(r'실패:\s+\[(.+?)\]\s+(.+)$');
    final finalFailExp = RegExp(r'최종 실패:\s+\[(.+?)\]\s+오류 발생:\s*(.+)$');
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
}

class _ParsedRatingLog {
  final bool isComplete;
  final Map<String, (RatingBatchItemStatus, String)> byReport;

  const _ParsedRatingLog({required this.isComplete, required this.byReport});
}
