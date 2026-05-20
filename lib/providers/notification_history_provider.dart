import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/notification_item.dart';
import '../models/rating_batch_result.dart';
import '../services/app_prefs_keys.dart';
import '../services/sync_engine.dart' show ChangeType;

class NotificationHistoryProvider with ChangeNotifier {
  static const _key = AppPrefsKeys.notificationsHistory;

  List<NotificationItem> _items = [];
  int _preferredTabIndex = 0;
  bool _loaded = false;

  List<NotificationItem> get items => List.unmodifiable(_items);
  int get unreadCount => _items.where((i) => !i.isRead).length;
  int get preferredTabIndex => _preferredTabIndex;

  void setPreferredTabIndex(int index, {bool notify = true}) {
    if (_preferredTabIndex == index) return;
    _preferredTabIndex = index;
    if (notify) notifyListeners();
  }

  static String normalizeReportNumber(String? value) {
    return value?.trim().toUpperCase() ?? '';
  }

  static String extractReportNumberFromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return '';
    return normalizeReportNumber(
      payload['신고번호']?.toString() ??
          payload['reportNumber']?.toString() ??
          payload['representative_report_number']?.toString(),
    );
  }

  String _reportNumberForItem(NotificationItem item) {
    final reportNumber = normalizeReportNumber(item.reportNumber);
    if (reportNumber.isNotEmpty) return reportNumber;
    return extractReportNumberFromPayload(item.extraData);
  }

  Future<void> load({bool notify = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // WsService가 직접 쓴 내용 반영
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _items = list
            .map((i) => NotificationItem.fromJson(i as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _items = [];
      }
    } else {
      _items = [];
    }
    _loaded = true;
    if (notify) notifyListeners();
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await load(notify: false);
  }

  Future<void> markRead(String id) async {
    await ensureLoaded();
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx >= 0 && !_items[idx].isRead) {
      _items[idx] = _items[idx].copyWith(isRead: true);
      await _save();
      notifyListeners();
    }
  }

  bool isReportRead(String reportNumber) {
    final normalized = normalizeReportNumber(reportNumber);
    if (normalized.isEmpty) return false;
    final matches = _items
        .where((item) => _reportNumberForItem(item) == normalized)
        .toList();
    if (matches.isEmpty) return false;
    return matches.every((item) => item.isRead);
  }

  bool isPayloadRead(Map<String, dynamic>? payload) {
    if ((payload?['notification_kind']?.toString() ?? '') == 'duplicate') {
      return false;
    }
    final reportNumber = extractReportNumberFromPayload(payload);
    if (reportNumber.isEmpty) return false;
    return isReportRead(reportNumber);
  }

  Future<void> markReportRead(String reportNumber) async {
    await ensureLoaded();
    final normalized = normalizeReportNumber(reportNumber);
    if (normalized.isEmpty) return;
    var changed = false;
    _items = _items.map((item) {
      if (_reportNumberForItem(item) == normalized && !item.isRead) {
        changed = true;
        return item.copyWith(isRead: true);
      }
      return item;
    }).toList();
    if (!changed) return;
    await _save();
    notifyListeners();
  }

  Future<void> markPayloadRead(Map<String, dynamic>? payload) async {
    if ((payload?['notification_kind']?.toString() ?? '') == 'duplicate') {
      return;
    }
    final reportNumber = extractReportNumberFromPayload(payload);
    if (reportNumber.isEmpty) return;
    await markReportRead(reportNumber);
  }

  Future<void> markAllRead() async {
    await ensureLoaded();
    _items = _items.map((i) => i.copyWith(isRead: true)).toList();
    await _save();
    notifyListeners();
  }

  Future<void> clearAll() async {
    _items = [];
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    notifyListeners();
  }

  Future<void> addFromServerResults(
    List<Map<String, dynamic>> serverData, {
    bool isMobileTriggered = false,
  }) async {
    await ensureLoaded();
    final now = DateTime.now();
    final ts =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final List<NotificationItem> newItems = [];

    if (serverData.isEmpty) {
      newItems.add(
        NotificationItem(
          id: '${now.millisecondsSinceEpoch}',
          kind: NotificationItemKind.crawl,
          title: isMobileTriggered ? '📱 크롤링 완료' : '🖥️ 크롤링 완료',
          body: '변경된 신고건이 없습니다.',
          reportNumber: '',
          timestamp: ts,
          isRead: false,
        ),
      );
    } else {
      final existingKeys = _items.map((item) {
        final extra = item.extraData ?? const <String, dynamic>{};
        if (item.kind == NotificationItemKind.duplicate) {
          final groupId = extra['group_id']?.toString() ?? '';
          final changeType = extra['duplicate_change_type']?.toString() ?? '';
          return 'duplicate:$groupId:$changeType';
        }
        if (item.reportNumber.isNotEmpty) {
          return 'report:${item.reportNumber}';
        }
        return 'generic:${item.id}';
      }).toSet();

      for (final r in serverData) {
        final notificationKind = r['notification_kind']?.toString() ?? 'report';
        if (notificationKind == 'duplicate') {
          final groupId = r['group_id']?.toString() ?? '';
          final duplicateChangeType =
              r['duplicate_change_type']?.toString() ?? '';
          final uniqueKey = 'duplicate:$groupId:$duplicateChangeType';
          if (groupId.isNotEmpty && existingKeys.contains(uniqueKey)) continue;

          final title = r['title']?.toString() ?? '🧩 중복 신고 변경';
          final body =
              r['body']?.toString() ??
              [
                if ((r['status_label']?.toString() ?? '').isNotEmpty)
                  '상태: ${r['status_label']}',
                if ((r['representative_report_number']?.toString() ?? '')
                    .isNotEmpty)
                  '대표 신고번호: ${r['representative_report_number']}',
                if ((r['member_count']?.toString() ?? '').isNotEmpty)
                  '멤버 수: ${r['member_count']}건',
              ].join('\n');

          newItems.add(
            NotificationItem(
              id: '${now.millisecondsSinceEpoch}_${groupId.isEmpty ? 'duplicate' : groupId}',
              kind: NotificationItemKind.duplicate,
              title: title,
              body: body,
              reportNumber:
                  r['representative_report_number']?.toString() ??
                  r['신고번호']?.toString() ??
                  '',
              timestamp: ts,
              isRead: false,
              extraData: Map<String, dynamic>.from(r),
            ),
          );
          existingKeys.add(uniqueKey);
          continue;
        }

        final rnum = r['신고번호']?.toString() ?? '';
        final uniqueKey = 'report:$rnum';
        if (rnum.isNotEmpty && existingKeys.contains(uniqueKey)) continue;
        final name = r['신고명']?.toString() ?? '신고';
        final status = r['처리상태']?.toString() ?? '';
        final agency = r['처리기관']?.toString() ?? '';
        final fine = r['범칙금_과태료']?.toString() ?? '';
        final changeType = r['change_type']?.toString() ?? '';
        final lines = <String>[];
        if (changeType.isNotEmpty) lines.add('[$changeType]');
        if (rnum.isNotEmpty) lines.add('신고번호: $rnum');
        if (status.isNotEmpty) lines.add('처리상태: $status');
        if (agency.isNotEmpty) lines.add('처리기관: $agency');
        if (fine.isNotEmpty && fine != 'null') lines.add('범칙금/과태료: $fine');
        // 카드 시트 (main.dart) 와 동일한 분류 기준 — magic string 대신 ChangeType 참조.
        final titleIcon = switch (changeType) {
          ChangeType.newReport => '🆕',
          ChangeType.individualConfirm => '✅',
          _ => '🔄',
        };
        newItems.add(
          NotificationItem(
            id: '${now.millisecondsSinceEpoch}_$rnum',
            kind: NotificationItemKind.report,
            title: '$titleIcon $name',
            body: lines.join('\n'),
            reportNumber: rnum,
            timestamp: ts,
            isRead: false,
            extraData: Map<String, dynamic>.from(r),
          ),
        );
        if (rnum.isNotEmpty) existingKeys.add(uniqueKey);
      }
    }

    if (newItems.isEmpty) return;
    _items.insertAll(0, newItems);
    await _save();
    notifyListeners();
  }

  Future<void> addRatingBatchResult(RatingBatchResult result) async {
    await ensureLoaded();
    _items.insert(
      0,
      NotificationItem(
        id: result.id,
        kind: NotificationItemKind.rating,
        title: result.title,
        body: result.summary,
        reportNumber: '',
        timestamp: result.timestamp,
        isRead: false,
        extraData: result.toJson(),
      ),
    );
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_items.map((i) => i.toJson()).toList()),
    );
  }
}
