import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:sqflite/sqflite.dart';

import '../models/duplicate_group.dart';
import '../storage/schema_utils.dart';
import 'performance_trace.dart';
import 'local_db_service.dart';

part 'bounded_duplicate_rebuild.dart';

class DuplicateProjectionService {
  static const groupTable = 'duplicate_group';
  static const memberTable = 'duplicate_member';

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $groupTable (
        group_id TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL,
        match_type TEXT NOT NULL,
        status TEXT NOT NULL,
        representative_mode TEXT NOT NULL DEFAULT 'auto',
        representative_id TEXT,
        member_count INTEGER NOT NULL DEFAULT 0,
        apply_globally INTEGER NOT NULL DEFAULT 1,
        note TEXT DEFAULT '',
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $memberTable (
        group_id TEXT NOT NULL,
        report_id TEXT NOT NULL,
        report_number TEXT NOT NULL,
        category TEXT NOT NULL,
        is_representative INTEGER NOT NULL DEFAULT 0,
        priority_score INTEGER NOT NULL DEFAULT 0,
        raw_match INTEGER NOT NULL DEFAULT 0,
        field_match INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER,
        updated_at INTEGER,
        PRIMARY KEY (group_id, report_id)
      )
    ''');
    await addColumnIfMissing(
      db,
      groupTable,
      'apply_globally',
      'INTEGER NOT NULL DEFAULT 1',
    );
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  static String _text(dynamic value) => value?.toString().trim() ?? '';

  /// 옛 중복군 상태 → 현재 상태. 서버 duplicate_group_service._LEGACY_STATUS_MAP 과 같다.
  static const _legacyStatusMap = {
    'auto': DuplicateStatuses.confirmedDuplicate,
    'confirmed': DuplicateStatuses.confirmedDuplicate,
    'review_required': DuplicateStatuses.reviewRequired,
    'excluded': DuplicateStatuses.notDuplicate,
  };

  /// 서버 `_normalize_duplicate_status` 와 같다: 소문자로 보고, 현재 값이면 그대로, 옛 값이면 변환, 아니면 ''.
  @visibleForTesting
  static String normalizeDuplicateStatus(dynamic value) {
    final v = _text(value).toLowerCase();
    if (const {
      DuplicateStatuses.reviewRequired,
      DuplicateStatuses.confirmedDuplicate,
      DuplicateStatuses.notDuplicate,
    }.contains(v)) {
      return v;
    }
    return _legacyStatusMap[v] ?? '';
  }

  /// 서버 `_normalize_representative_mode` 와 같다: 현재 값이면 그대로, 옛 상태가 confirmed 면 manual, 아니면 auto.
  @visibleForTesting
  static String normalizeRepresentativeMode(
    dynamic value, {
    dynamic existingStatus,
  }) {
    final v = _text(value).toLowerCase();
    if (v == RepresentativeModes.manual || v == RepresentativeModes.auto) {
      return v;
    }
    return _text(existingStatus).toLowerCase() == 'confirmed'
        ? RepresentativeModes.manual
        : RepresentativeModes.auto;
  }

  static String _normalizeInline(dynamic value) {
    return _text(value).replaceAll(RegExp(r'\s+'), ' ');
  }

  static String normalizeRawContent(dynamic rawContent) {
    var text = _text(
      rawContent,
    ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n+'), '\n');
    return text.trim();
  }

  static String _payloadHash(String rawContent) {
    return crypto.sha256.convert(utf8.encode(rawContent)).toString();
  }

  static String _legacyPayloadHash(String rawContent) {
    var hash = 1469598103934665603;
    for (final unit in utf8.encode(rawContent)) {
      hash ^= unit;
      hash *= 1099511628211;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  static String _fieldFingerprint(Map<String, dynamic> record) {
    final parts = [
      _normalizeInline(record['category']),
      _normalizeInline(record['entry_value']),
      _normalizeInline(record['차량번호']),
      _normalizeInline(record['신고내용']),
      _normalizeInline(record['발생일자']),
      _normalizeInline(record['발생시각']),
      _normalizeInline(record['위반장소']),
    ];
    return parts.join('|');
  }

  static int _parseMillis(dynamic value) {
    final text = _text(value);
    if (text.isEmpty) return 0;
    return DateTime.tryParse(text)?.millisecondsSinceEpoch ?? 0;
  }

  static const _statusPriority = <String, int>{
    '수용': 5,
    '일부수용': 4,
    '기타': 3,
    '불수용': 2,
    '답변완료': 1,
    '처리중': 0,
    '진행': 0,
    '진행중': 0,
    '검토중': 0,
    '취하': -1,
  };

  static List<Comparable<dynamic>> _priorityTuple(Map<String, dynamic> record) {
    final fineText = _text(record['범칙금_과태료']);
    final fineRank = fineText.contains('과태료')
        ? 2
        : RegExp(r'경고|범칙금').hasMatch(fineText)
        ? 1
        : 0;
    final statusRank = _statusPriority[_text(record['처리상태'])] ?? -2;
    final answerRank = _parseMillis(record['답변일']);
    final syncedRank = int.tryParse(_text(record['synced_at'])) ?? 0;
    return [
      fineRank,
      statusRank,
      answerRank,
      syncedRank,
      _text(record['신고번호']),
    ];
  }

  static int _compareTuple(
    List<Comparable<dynamic>> left,
    List<Comparable<dynamic>> right,
  ) {
    for (var i = 0; i < left.length; i++) {
      final result = left[i].compareTo(right[i]);
      if (result != 0) return result;
    }
    return 0;
  }

  static Future<Map<String, dynamic>> refreshDuplicateGroups(
    Database db, {
    bool trackChanges = false,
  }) => LocalDbService.runBackgroundWork(
    () => _BoundedDuplicateRebuild.run(db, trackChanges: trackChanges),
  );

  static Map<String, dynamic> _buildDuplicateAlertPayload({
    required String changeKind,
    required String groupId,
    required String status,
    required String representativeMode,
    required int memberCount,
    required Map<String, dynamic> representative,
    required List<Map<String, dynamic>> members,
  }) {
    final statusLabel = DuplicateStatuses.labelOf(status);
    final modeLabel = RepresentativeModes.labelOf(representativeMode);
    final reportNumber = _text(representative['신고번호']);
    final changeLabel = switch (changeKind) {
      'group_added' => '신규 중복군',
      'members_changed' => '중복군 변경',
      _ => '대표건 변경',
    };
    final bodyLines = <String>[
      switch (changeKind) {
        'group_added' => '중복 신고 그룹이 새로 감지되었습니다.',
        'members_changed' => '중복 신고 그룹의 멤버 구성이 변경되었습니다.',
        _ => '중복 신고 그룹의 대표건이 자동으로 변경되었습니다.',
      },
    ];
    if (reportNumber.isNotEmpty) {
      bodyLines.add('대표 신고번호: $reportNumber');
    }
    bodyLines.add('현재 상태: $statusLabel');
    bodyLines.add('대표건 모드: $modeLabel');
    bodyLines.add('멤버 수: $memberCount건');

    return {
      'notification_kind': 'duplicate',
      'duplicate_change_type': changeKind,
      'change_type': changeLabel,
      'group_id': groupId,
      'status': status,
      'status_label': statusLabel,
      'representative_mode': representativeMode,
      'representative_mode_label': modeLabel,
      'member_count': memberCount,
      'representative_id': _text(representative['report_id']),
      'representative': representative,
      'members': members,
      'title': '🧩 $statusLabel — $changeLabel',
      'body': bodyLines.join('\n'),
      '신고번호': reportNumber,
      '신고명': _text(representative['신고명']),
      '처리상태': _text(representative['처리상태']),
      '처리기관': _text(representative['처리기관']),
      '범칙금_과태료': _text(representative['범칙금_과태료']),
    };
  }

  static Future<bool> hasCompletedProjection(DatabaseExecutor db) async {
    if ((await db.rawQuery("SELECT 1 FROM sqlite_master WHERE name=?", [
      _BoundedDuplicateRebuild.meta,
    ])).isEmpty) {
      return false;
    }
    final columns = await db.rawQuery(
      'PRAGMA table_info(${_BoundedDuplicateRebuild.meta})',
    );
    if (!columns.any((r) => r['name'] == 'built_revision')) return false;
    return (await db.rawQuery(
      'SELECT 1 FROM ${_BoundedDuplicateRebuild.meta} WHERE id=1 AND built_revision>=0',
    )).isNotEmpty;
  }

  static Future<List<DuplicateMember>> getDuplicateMembers(
    DatabaseExecutor db,
    String groupId, {
    int page = 0,
    int pageSize = 50,
  }) async {
    final size = pageSize.clamp(1, 100);
    final rows = await PerformanceTrace.sql(
      'duplicate.member_page',
      () => db.rawQuery(
        '''
      SELECT r.*,m.* FROM duplicate_member m JOIN reports r ON r.ID=m.report_id
      WHERE m.group_id=? ORDER BY m.is_representative DESC,m.report_number DESC,m.report_id DESC
      LIMIT ? OFFSET ?
    ''',
        [groupId, size, page.clamp(0, 1 << 30) * size],
      ),
    );
    return rows.map(DuplicateMember.fromJson).toList();
  }

  static Future<List<DuplicateGroup>> getDuplicateGroups(
    DatabaseExecutor db, {
    String? status,
    int page = 0,
    int pageSize = 50,
  }) async {
    final normalizedStatus = _text(status);
    final size = pageSize.clamp(1, 100);
    // Sorting and COUNT apply to the complete population, before pagination.
    final rows = await db.rawQuery(
      '''
      SELECT g.* FROM duplicate_group g LEFT JOIN reports r ON r.ID=g.representative_id
      ${normalizedStatus.isEmpty ? '' : 'WHERE g.status=?'}
      ORDER BY COALESCE(r.신고번호,'') DESC,g.member_count DESC,g.group_id DESC LIMIT ? OFFSET ?
    ''',
      [
        if (normalizedStatus.isNotEmpty) normalizedStatus,
        size,
        page.clamp(0, 1 << 30) * size,
      ],
    );
    final groups = <DuplicateGroup>[];
    for (final row in rows) {
      final members = await getDuplicateMembers(db, row['group_id'] as String);
      groups.add(
        DuplicateGroup.fromJson({
          ...row,
          'members': members.map((m) => m.toJson()).toList(),
        }),
      );
    }
    return groups;
  }

  /// 사용자 판단을 duplicate_decision 에 남긴다(서버 _record_decisions 와 같음). 그룹 재생성에도 보존된다.
  static Future<void> _recordDecisions(
    DatabaseExecutor db,
    List<String> groupIds,
  ) async {
    for (final groupId in groupIds) {
      final rows = await db.query(
        groupTable,
        where: 'group_id = ?',
        whereArgs: [groupId],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      final g = rows.first;
      await db.insert('duplicate_decision', {
        'group_id': groupId,
        'status': g['status'],
        'representative_mode': g['representative_mode'],
        'representative_id': g['representative_id'],
        'apply_globally': g['apply_globally'],
        'note': g['note'],
        'updated_at': g['updated_at'] ?? _nowMs(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<bool> updateDuplicateGroup(
    Database db,
    String groupId, {
    String? representativeId,
    String? duplicateStatus,
    String? representativeMode,
    String? note,
  }) async {
    final normalizedGroupId = _text(groupId);
    if (normalizedGroupId.isEmpty) return false;
    final rows = await db.query(
      groupTable,
      where: 'group_id = ?',
      whereArgs: [normalizedGroupId],
      limit: 1,
    );
    if (rows.isEmpty) return false;

    final currentGroup = Map<String, dynamic>.from(rows.first);
    final currentStatus = _text(currentGroup['status']).isEmpty
        ? DuplicateStatuses.confirmedDuplicate
        : _text(currentGroup['status']);
    final currentMode =
        _text(currentGroup['representative_mode']) == RepresentativeModes.manual
        ? RepresentativeModes.manual
        : RepresentativeModes.auto;

    final members = await db.query(
      memberTable,
      columns: ['report_id'],
      where: 'group_id = ?',
      whereArgs: [normalizedGroupId],
      limit: 1,
    );
    if (members.isEmpty) return false;

    Future<bool> containsMember(String id) async =>
        id.isNotEmpty &&
        (await db.rawQuery(
          'SELECT 1 FROM duplicate_member m JOIN reports r ON r.ID=m.report_id WHERE m.group_id=? AND m.report_id=? LIMIT 1',
          [normalizedGroupId, id],
        )).isNotEmpty;

    final nextStatus =
        {
          DuplicateStatuses.reviewRequired,
          DuplicateStatuses.confirmedDuplicate,
          DuplicateStatuses.notDuplicate,
        }.contains(_text(duplicateStatus))
        ? _text(duplicateStatus)
        : currentStatus;
    var nextMode = _text(representativeMode) == RepresentativeModes.manual
        ? RepresentativeModes.manual
        : _text(representativeMode) == RepresentativeModes.auto
        ? RepresentativeModes.auto
        : currentMode;

    final requestedRepresentativeId = _text(representativeId);
    final requestedValid = await containsMember(requestedRepresentativeId);
    final currentValid = await containsMember(
      _text(currentGroup['representative_id']),
    );
    // Rank only narrow keys in bounded pages, never all member originals.
    Map<String, dynamic>? recommended;
    var cursor = '';
    if (nextMode == RepresentativeModes.auto ||
        !requestedValid && !currentValid) {
      while (true) {
        final page = await db.rawQuery(
          '''
        SELECT r.ID,r.범칙금_과태료,r.처리상태,r.답변일,r.synced_at,r.신고번호,m.priority_score
        FROM duplicate_member m JOIN reports r ON r.ID=m.report_id
        WHERE m.group_id=? AND m.report_id>? ORDER BY m.report_id LIMIT 128
      ''',
          [normalizedGroupId, cursor],
        );
        if (page.isEmpty) break;
        for (final row in page) {
          final comparison = recommended == null
              ? 1
              : _compareTuple(_priorityTuple(row), _priorityTuple(recommended));
          if (comparison > 0 ||
              comparison == 0 &&
                  (row['priority_score'] as int) >
                      (recommended!['priority_score'] as int)) {
            recommended = Map<String, dynamic>.from(row);
          }
        }
        cursor = page.last['ID'] as String;
        await Future<void>.delayed(Duration.zero);
      }
      if (recommended == null) return false;
    }
    final autoRepresentativeId = _text(recommended?['ID']);
    if (nextMode == RepresentativeModes.auto &&
        requestedRepresentativeId.isNotEmpty &&
        requestedValid &&
        requestedRepresentativeId != autoRepresentativeId) {
      nextMode = RepresentativeModes.manual;
    }

    String resolvedRepresentativeId = _text(currentGroup['representative_id']);
    if (nextMode == RepresentativeModes.manual) {
      if (requestedRepresentativeId.isNotEmpty && requestedValid) {
        resolvedRepresentativeId = requestedRepresentativeId;
      } else if (!currentValid) {
        resolvedRepresentativeId = autoRepresentativeId;
      }
    } else {
      resolvedRepresentativeId = autoRepresentativeId;
    }

    final updatedAt = _nowMs();
    await db.transaction((txn) async {
      await txn.update(
        groupTable,
        {
          'status': nextStatus,
          'representative_mode': nextMode,
          'representative_id': resolvedRepresentativeId,
          'apply_globally': nextStatus == DuplicateStatuses.confirmedDuplicate
              ? 1
              : 0,
          'note': note ?? currentGroup['note']?.toString() ?? '',
          'updated_at': updatedAt,
        },
        where: 'group_id = ?',
        whereArgs: [normalizedGroupId],
      );
      await txn.update(
        memberTable,
        {'is_representative': 0, 'updated_at': updatedAt},
        where: 'group_id = ?',
        whereArgs: [normalizedGroupId],
      );
      await txn.update(
        memberTable,
        {'is_representative': 1, 'updated_at': updatedAt},
        where: 'group_id = ? AND report_id = ?',
        whereArgs: [normalizedGroupId, resolvedRepresentativeId],
      );
      await _recordDecisions(txn, [normalizedGroupId]);
    });
    return true;
  }

  static Future<int> bulkUpdateStatus(
    DatabaseExecutor db,
    List<String> groupIds,
    String duplicateStatus,
  ) async {
    final normalizedIds = groupIds
        .map(_text)
        .where((item) => item.isNotEmpty)
        .toList();
    final normalizedStatus = _text(duplicateStatus);
    if (normalizedIds.isEmpty ||
        !{
          DuplicateStatuses.reviewRequired,
          DuplicateStatuses.confirmedDuplicate,
          DuplicateStatuses.notDuplicate,
        }.contains(normalizedStatus)) {
      return 0;
    }
    final placeholders = List.filled(normalizedIds.length, '?').join(',');
    final changed = await db.rawUpdate(
      '''
      UPDATE $groupTable
      SET status = ?, apply_globally = ?, updated_at = ?
      WHERE group_id IN ($placeholders)
      ''',
      [
        normalizedStatus,
        normalizedStatus == DuplicateStatuses.confirmedDuplicate ? 1 : 0,
        _nowMs(),
        ...normalizedIds,
      ],
    );
    await _recordDecisions(db, normalizedIds);
    return changed;
  }

  static Future<List<Map<String, dynamic>>> projectReportRows(
    DatabaseExecutor db,
    List<Map<String, dynamic>> rows, {
    required bool useRepresentativeRecords,
  }) async {
    if (!useRepresentativeRecords || rows.isEmpty) return rows;
    final groups = await db.query(
      groupTable,
      where: 'status = ?',
      whereArgs: [DuplicateStatuses.confirmedDuplicate],
    );
    if (groups.isEmpty) return rows;

    final groupIds = groups.map((row) => _text(row['group_id'])).toList();
    final placeholders = List.filled(groupIds.length, '?').join(',');
    final memberRows = await db.rawQuery(
      'SELECT * FROM $memberTable WHERE group_id IN ($placeholders)',
      groupIds,
    );
    if (memberRows.isEmpty) return rows;

    final memberMap = <String, Map<String, dynamic>>{};
    final memberCountByGroup = <String, int>{};
    for (final row in memberRows) {
      final groupId = _text(row['group_id']);
      memberCountByGroup[groupId] = (memberCountByGroup[groupId] ?? 0) + 1;
      memberMap[_text(row['report_id'])] = Map<String, dynamic>.from(row);
    }

    final groupWatchFlags = <String, String>{};
    for (final row in rows) {
      final reportId = _text(row['ID']);
      final meta = memberMap[reportId];
      if (meta == null) continue;
      final groupId = _text(meta['group_id']);
      if (_text(row['감시목록']) == 'Y') {
        groupWatchFlags[groupId] = 'Y';
      } else {
        groupWatchFlags.putIfAbsent(groupId, () => 'N');
      }
    }

    final projected = <Map<String, dynamic>>[];
    for (final row in rows) {
      final reportId = _text(row['ID']);
      final meta = memberMap[reportId];
      if (meta == null) {
        projected.add(Map<String, dynamic>.from(row));
        continue;
      }
      final item = Map<String, dynamic>.from(row);
      final groupId = _text(meta['group_id']);
      item['duplicate_group_id'] = groupId;
      item['duplicate_member_count'] = memberCountByGroup[groupId] ?? 0;
      item['is_duplicate_representative'] =
          (meta['is_representative'] as int? ?? 0) == 1;
      if (groupWatchFlags[groupId] == 'Y') {
        item['감시목록'] = 'Y';
      }
      if ((meta['is_representative'] as int? ?? 0) != 1) {
        continue;
      }
      projected.add(item);
    }
    return projected;
  }
}
