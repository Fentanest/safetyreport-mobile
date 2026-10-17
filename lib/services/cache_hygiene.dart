import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 앱 캐시 폴더 정리(2026-10-17 사용자 제보 — 매일 쓰던 2.2 Standalone 이 '다시 불러오기 판정 실패'로 막혔고 캐시 삭제 뒤 정상).
///
/// 캐시에는 앱이 만든 임시 자료만 정리한다. DB 파일(databases 폴더)·사용자 내보내기(Documents)는 건드리지 않는다.
/// - 스테이징 폴더(`Directory.systemTemp.createTemp`): 가져오기·복원·중복 재계산이 `finally` 에서 지우지만,
///   도중에 프로세스가 끝나면 DB 사본 크기 그대로 남는다.
/// - 백업 내보내기 사본(`backup_data_*.db`)·파일 열기 사본(`open_*`): 위와 같다.
/// - 첨부 캐시(`attachments/<key>/`, [AttachmentCache]): 지우는 코드가 없어 본 사진·영상이 계속 쌓인다.
///   지워도 다음에 볼 때 다시 받는다.
/// 쓰는 중일 수 있는 항목(최근 [stagingAge] 안에 바뀐 것)은 남긴다 — 백그라운드 엔진이 같은 폴더를 쓸 수 있다.
class CacheHygiene {
  CacheHygiene._();

  /// 이 접두사로 시작하는 캐시 폴더는 앱의 스테이징 폴더다(호출 위치: settings_screen·local_db_service·bounded_duplicate_rebuild).
  static const stagingDirPrefixes = [
    'mysafetyreport_pick_',
    'mysafetyreport_import_',
    'mysafetyreport_restore_staged_',
    'sr_duplicate_stage_',
  ];

  /// 이 접두사로 시작하는 캐시 파일은 앱이 만든 일회용 사본이다(DbExportLocation.stage·file_browser_screen).
  static const stagingFilePrefixes = ['backup_data_', 'open_'];

  static const attachmentsDirName = 'attachments';

  /// 평소: 이보다 오래된 스테이징만 지운다. 정리 요청(저장공간 부족 복구): [aggressiveStagingAge].
  static const stagingAge = Duration(hours: 6);
  static const aggressiveStagingAge = Duration(minutes: 10);

  /// 첨부 캐시: 이 기간 동안 안 바뀐 항목, 그리고 합계가 [attachmentBudgetBytes] 를 넘으면 오래된 것부터.
  static const attachmentMaxAge = Duration(days: 14);
  static const attachmentBudgetBytes = 300 * 1024 * 1024;

  static Future<CacheHygieneReport>? _startup;

  /// 앱 시작 때 한 번(프로세스당). 실패는 무시한다 — 정리는 시작을 막지 않는다.
  static Future<CacheHygieneReport> runAtStartup() =>
      _startup ??= run().catchError((Object _) => const CacheHygieneReport());

  /// 캐시를 정리한다. [aggressive] 면 첨부 캐시를 (최근 사용 중인 것 빼고) 모두, 스테이징은 10분 넘은 것을 지운다.
  /// [roots] 를 주지 않으면 앱 캐시 폴더와 `Directory.systemTemp`(Android 는 보통 같은 폴더).
  static Future<CacheHygieneReport> run({
    bool aggressive = false,
    List<Directory>? roots,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final staleBefore = at.subtract(
      aggressive ? aggressiveStagingAge : stagingAge,
    );
    final resolved = roots ?? await _defaultRoots();
    var report = const CacheHygieneReport();
    final seen = <String>{};
    for (final root in resolved) {
      final key = p.normalize(root.absolute.path);
      if (!seen.add(key)) continue;
      try {
        if (!await root.exists()) continue;
        report += await _cleanRoot(
          root,
          staleBefore: staleBefore,
          attachmentsBefore: aggressive
              ? staleBefore
              : at.subtract(attachmentMaxAge),
          budget: aggressive ? 0 : attachmentBudgetBytes,
        );
      } catch (e) {
        debugPrint('[cache-hygiene] $key: $e');
      }
    }
    if (report.deletedEntries > 0) {
      debugPrint(
        '[cache-hygiene] deleted ${report.deletedEntries} entries, '
        '${report.deletedBytes} bytes (aggressive=$aggressive)',
      );
    }
    return report;
  }

  static Future<List<Directory>> _defaultRoots() async {
    final roots = <Directory>[];
    try {
      roots.add(await getTemporaryDirectory());
    } catch (_) {}
    try {
      roots.add(Directory.systemTemp);
    } catch (_) {}
    return roots;
  }

  static Future<CacheHygieneReport> _cleanRoot(
    Directory root, {
    required DateTime staleBefore,
    required DateTime attachmentsBefore,
    required int budget,
  }) async {
    var report = const CacheHygieneReport();
    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      try {
        if (entity is Directory) {
          if (name == attachmentsDirName) {
            report += await _cleanAttachments(
              entity,
              staleBefore: staleBefore,
              attachmentsBefore: attachmentsBefore,
              budget: budget,
            );
          } else if (stagingDirPrefixes.any(name.startsWith)) {
            final usage = await _usage(entity);
            if (usage.newest.isBefore(staleBefore)) {
              await entity.delete(recursive: true);
              report += CacheHygieneReport(1, usage.bytes);
            }
          }
        } else if (entity is File && stagingFilePrefixes.any(name.startsWith)) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(staleBefore)) {
            await entity.delete();
            report += CacheHygieneReport(1, stat.size);
          }
        }
      } catch (e) {
        debugPrint('[cache-hygiene] $name: $e');
      }
    }
    return report;
  }

  static Future<CacheHygieneReport> _cleanAttachments(
    Directory dir, {
    required DateTime staleBefore,
    required DateTime attachmentsBefore,
    required int budget,
  }) async {
    var report = const CacheHygieneReport();
    final kept = <(Directory, _Usage)>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      try {
        // 끝나지 못한 내려받기 조각(.part)은 오래되면 지운다.
        await for (final f in entity.list(followLinks: false)) {
          if (f is File && f.path.endsWith('.part')) {
            final stat = await f.stat();
            if (stat.modified.isBefore(staleBefore)) {
              await f.delete();
              report += CacheHygieneReport(1, stat.size);
            }
          }
        }
        final usage = await _usage(entity);
        if (usage.newest.isBefore(attachmentsBefore)) {
          await entity.delete(recursive: true);
          report += CacheHygieneReport(1, usage.bytes);
        } else {
          kept.add((entity, usage));
        }
      } catch (e) {
        debugPrint('[cache-hygiene] attachment ${p.basename(entity.path)}: $e');
      }
    }
    var total = kept.fold<int>(0, (sum, k) => sum + k.$2.bytes);
    if (total <= budget) return report;
    kept.sort((a, b) => a.$2.newest.compareTo(b.$2.newest));
    for (final (entry, usage) in kept) {
      if (total <= budget) break;
      // 지금 내려받는 중일 수 있는 항목은 남긴다.
      if (!usage.newest.isBefore(staleBefore)) continue;
      try {
        await entry.delete(recursive: true);
        total -= usage.bytes;
        report += CacheHygieneReport(1, usage.bytes);
      } catch (_) {}
    }
    return report;
  }

  static Future<_Usage> _usage(Directory dir) async {
    var bytes = 0;
    var newest = (await dir.stat()).modified;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      final stat = await e.stat();
      if (stat.type == FileSystemEntityType.file) bytes += stat.size;
      if (stat.modified.isAfter(newest)) newest = stat.modified;
    }
    return _Usage(bytes, newest);
  }
}

class _Usage {
  const _Usage(this.bytes, this.newest);
  final int bytes;
  final DateTime newest;
}

@immutable
class CacheHygieneReport {
  const CacheHygieneReport([this.deletedEntries = 0, this.deletedBytes = 0]);
  final int deletedEntries;
  final int deletedBytes;

  CacheHygieneReport operator +(CacheHygieneReport other) => CacheHygieneReport(
    deletedEntries + other.deletedEntries,
    deletedBytes + other.deletedBytes,
  );
}
