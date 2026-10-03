import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';

import 'package:safetyreport/models/duplicate_group.dart';
import 'package:safetyreport/storage/schema_utils.dart';

class LegacyDuplicateRebuild {
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

  static Map<String, dynamic> _chooseRepresentative(
    List<Map<String, dynamic>> records,
  ) {
    final ranked = [...records]
      ..sort((a, b) => _compareTuple(_priorityTuple(b), _priorityTuple(a)));
    return ranked.first;
  }

  static Future<List<Map<String, dynamic>>> _loadInventory(
    DatabaseExecutor db,
  ) async {
    final rows = await db.rawQuery('''
      SELECT
        r.*,
        COALESCE(rr.raw_content, '') AS raw_content,
        COALESCE(rr.raw_type, '') AS raw_type,
        rr.saved_at AS saved_at
      FROM reports r
      LEFT JOIN report_raw rr ON rr.ID = r.ID
    ''');
    return rows.map((row) {
      final item = Map<String, dynamic>.from(row);
      final normalized = normalizeRawContent(item['raw_content']);
      item['payload_normalized'] = normalized;
      item['payload_hash'] = normalized.isEmpty ? '' : _payloadHash(normalized);
      item['payload_hash_legacy'] = normalized.isEmpty
          ? ''
          : _legacyPayloadHash(normalized);
      return item;
    }).toList();
  }

  static Future<Map<String, dynamic>> refreshDuplicateGroups(
    Database db, {
    bool trackChanges = false,
  }) async {
    final inventory = await _loadInventory(db);
    final existingGroups = <String, Map<String, dynamic>>{};
    final existingGroupsByLegacyId = <String, Map<String, dynamic>>{};
    final existingGroupRows = await db.query(groupTable);
    for (final row in existingGroupRows) {
      final normalized = Map<String, dynamic>.from(row);
      final groupId = row['group_id']?.toString() ?? '';
      if (groupId.isNotEmpty) {
        existingGroups[groupId] = normalized;
      }
      final legacyKey = row['fingerprint']?.toString() ?? '';
      if (legacyKey.isNotEmpty) {
        existingGroupsByLegacyId[legacyKey] = normalized;
      }
    }

    // 사용자 판단(duplicate_decision)이 기존 그룹 행보다 우선한다 — 그룹이 사라졌다 다시 생겨도 유지(결정 D-6, M-18).
    for (final decision in await db.query('duplicate_decision')) {
      final groupId = decision['group_id']?.toString() ?? '';
      if (groupId.isEmpty) continue;
      existingGroups[groupId] = {
        ...?existingGroups[groupId],
        for (final key in const [
          'status',
          'representative_mode',
          'representative_id',
          'note',
        ])
          key: decision[key],
      };
    }

    final existingMembersByGroup = <String, Set<String>>{};
    final memberCreatedAt = <String, Object?>{};
    for (final row in await db.query(memberTable)) {
      final groupId = row['group_id']?.toString() ?? '';
      final reportId = row['report_id']?.toString() ?? '';
      if (groupId.isEmpty || reportId.isEmpty) continue;
      existingMembersByGroup
          .putIfAbsent(groupId, () => <String>{})
          .add(reportId);
      memberCreatedAt['$groupId|$reportId'] = row['created_at'];
    }

    final duplicateCandidates = inventory
        .where((item) => _text(item['payload_hash']).isNotEmpty)
        .toList();
    final counts = <String, int>{};
    for (final row in duplicateCandidates) {
      final key = row['payload_hash']?.toString() ?? '';
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final groups = <Map<String, dynamic>>[];
    final members = <Map<String, dynamic>>[];
    final alerts = <Map<String, dynamic>>[];
    final currentTs = _nowMs();

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in duplicateCandidates) {
      final key = row['payload_hash']?.toString() ?? '';
      if ((counts[key] ?? 0) <= 1) continue;
      grouped.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(row);
    }

    for (final entry in grouped.entries) {
      final groupId = entry.key;
      final records = entry.value;
      if (records.length <= 1) continue;

      final recommendedRepresentative = _chooseRepresentative(records);
      final recommendedRepresentativeId = _text(
        recommendedRepresentative['ID'],
      );
      final legacyGroupId = _text(records.first['payload_hash_legacy']);
      final existing =
          existingGroups[groupId] ??
          (legacyGroupId.isEmpty
              ? null
              : existingGroupsByLegacyId[legacyGroupId]);
      final preservedStatus = normalizeDuplicateStatus(existing?['status']);
      final preservedMode = existing == null
          ? ''
          : normalizeRepresentativeMode(
              existing['representative_mode'],
              existingStatus: existing['status'],
            );
      final preservedRep = _text(existing?['representative_id']);
      final createdAt =
          int.tryParse(existing?['created_at']?.toString() ?? '') ?? currentTs;

      final representativeMode = preservedMode == RepresentativeModes.manual
          ? RepresentativeModes.manual
          : RepresentativeModes.auto;

      final carValues = records
          .map((row) => _text(row['차량번호']))
          .where((value) => value.isNotEmpty)
          .toSet();
      final categoryValues = records
          .map((row) => _text(row['category']))
          .where((value) => value.isNotEmpty)
          .toSet();
      final entryValues = records
          .map((row) => _text(row['entry_value']))
          .where((value) => value.isNotEmpty)
          .toSet();
      final hasConflict =
          carValues.length > 1 ||
          categoryValues.length > 1 ||
          entryValues.length > 1;

      final defaultStatus = hasConflict
          ? DuplicateStatuses.reviewRequired
          : DuplicateStatuses.confirmedDuplicate;
      final status =
          {
            DuplicateStatuses.reviewRequired,
            DuplicateStatuses.confirmedDuplicate,
            DuplicateStatuses.notDuplicate,
          }.contains(preservedStatus)
          ? preservedStatus
          : defaultStatus;

      final memberIds = records.map((row) => _text(row['ID'])).toSet();
      var representativeId = recommendedRepresentativeId;
      if (representativeMode == RepresentativeModes.manual &&
          preservedRep.isNotEmpty &&
          memberIds.contains(preservedRep)) {
        representativeId = preservedRep;
      }

      groups.add({
        'group_id': groupId,
        'fingerprint': groupId,
        'match_type': 'payload_exact',
        'status': status,
        'representative_mode': representativeMode,
        'representative_id': representativeId,
        'member_count': records.length,
        'apply_globally': status == DuplicateStatuses.confirmedDuplicate
            ? 1
            : 0,
        'note': existing?['note']?.toString() ?? '',
        'created_at': createdAt,
        'updated_at': currentTs,
      });

      final fingerprints = records.map(_fieldFingerprint).toList();
      var majorityFingerprint = '';
      if (fingerprints.isNotEmpty) {
        final freq = <String, int>{};
        for (final fingerprint in fingerprints) {
          freq[fingerprint] = (freq[fingerprint] ?? 0) + 1;
        }
        majorityFingerprint =
            (freq.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                .first
                .key;
      }

      final ranked = [...records]
        ..sort((a, b) => _compareTuple(_priorityTuple(b), _priorityTuple(a)));
      final memberPayloads = <Map<String, dynamic>>[];
      for (var index = 0; index < ranked.length; index++) {
        final record = ranked[index];
        final isRepresentative = _text(record['ID']) == representativeId;
        final payload = {
          'group_id': groupId,
          'report_id': _text(record['ID']),
          'report_number': _text(record['신고번호']),
          'category': _text(record['category']),
          'is_representative': isRepresentative ? 1 : 0,
          'priority_score': ranked.length - index,
          'raw_match': 1,
          'field_match': _fieldFingerprint(record) == majorityFingerprint
              ? 1
              : 0,
          'created_at':
              memberCreatedAt['$groupId|${_text(record['ID'])}'] ??
              currentTs, // 처음 묶인 시각 유지
          'updated_at': currentTs,
        };
        members.add(payload);
        memberPayloads.add({...Map<String, dynamic>.from(record), ...payload});
      }

      if (trackChanges) {
        final previousMemberIds = existingMembersByGroup[groupId] ?? <String>{};
        final currentMemberIds = ranked.map((row) => _text(row['ID'])).toSet();
        final autoRepresentativeChanged =
            existing != null &&
            representativeMode == RepresentativeModes.auto &&
            _text(existing['representative_id']) != representativeId;
        final membersChanged =
            existing != null &&
                previousMemberIds.length == currentMemberIds.length
            ? previousMemberIds.difference(currentMemberIds).isNotEmpty
            : existing != null &&
                  previousMemberIds.length != currentMemberIds.length;

        String changeKind = '';
        if (existing == null) {
          changeKind = 'group_added';
        } else if (membersChanged) {
          changeKind = 'members_changed';
        } else if (autoRepresentativeChanged) {
          changeKind = 'representative_changed';
        }

        if (changeKind.isNotEmpty) {
          final representative = memberPayloads.firstWhere(
            (member) => (member['is_representative'] as int? ?? 0) == 1,
            orElse: () => <String, dynamic>{},
          );
          alerts.add(
            _buildDuplicateAlertPayload(
              changeKind: changeKind,
              groupId: groupId,
              status: status,
              representativeMode: representativeMode,
              memberCount: memberPayloads.length,
              representative: representative,
              members: memberPayloads,
            ),
          );
        }
      }
    }

    await db.transaction((txn) async {
      await txn.delete(memberTable);
      await txn.delete(groupTable);
      if (groups.isNotEmpty) {
        final batch = txn.batch();
        for (final row in groups) {
          batch.insert(
            groupTable,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final row in members) {
          batch.insert(
            memberTable,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
    });

    return {
      'group_count': groups.length,
      'member_count': members.length,
      'changes': alerts,
    };
  }

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
}
