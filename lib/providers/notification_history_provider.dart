import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../community/community_store.dart' show newUuidV4;
import '../models/notification_item.dart';
import '../models/rating_batch_result.dart';
import '../services/app_prefs_keys.dart';
import '../services/prefs_inbox.dart';
import '../services/sync_engine.dart' show ChangeType;

/// Client 모드 서버 결과 확인 한 번의 결과.
/// [ok] 가 false 면 조회·저장·완료 확인 가운데 하나가 실패했다(완료 신호는 저장 뒤에만 소비하므로 다시 시도할 수 있다).
/// [doneChangedCount] 는 서버 완료 신호를 이번에 소비했을 때만 값이 있다.
typedef ServerCrawlPoll = ({bool ok, int? doneChangedCount});

/// 알림 기록(알림 탭 3개 하위 탭의 자료).
///
/// - 모든 읽기·쓰기는 한 줄로 세운 작업 큐에서 차례로 돈다(SQ-B02). 다시 읽기가 저장 중인 새 항목을 덮지 않는다.
/// - 읽음·중복 판정은 신고번호가 아니라 "변경 하나"(신고번호+변경 종류+처리상태+동기화 시각+답변일) 단위다(SQ-B01).
/// - 저장 원문이 그대로면 다시 해석하거나 알리지 않고, 읽음 표시 저장은 몰아서 한다(SQ-P08).
class NotificationHistoryProvider with ChangeNotifier {
  static const _key = AppPrefsKeys.notificationsHistory;
  static const _maxItems = 200;

  List<NotificationItem> _items = [];
  int _preferredTabIndex = 0;
  bool _loaded = false;

  /// 마지막으로 읽었거나 쓴 저장 원문. 같으면 다시 해석하지 않는다.
  String? _storedRaw;

  /// 메모리에는 반영했지만 아직 저장하지 못한 변경이 있다(저장 실패 뒤 다음 작업이 다시 저장한다).
  bool _dirty = false;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _pendingFlush;
  Future<ServerCrawlPoll>? _serverPoll;

  List<NotificationItem> get items => List.unmodifiable(_items);
  int get unreadCount => _items.where((i) => !i.isRead).length;
  int get preferredTabIndex => _preferredTabIndex;

  void setPreferredTabIndex(int index, {bool notify = true}) {
    if (_preferredTabIndex == index) return;
    _preferredTabIndex = index;
    if (notify) _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 작업을 큐 끝에 붙인다. 앞 작업이 실패해도 큐는 이어진다.
  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  // ── 식별 ──────────────────────────────────────────────────────────────────

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

  static String _text(Object? value) {
    if (value == null) return '';
    final text = value.toString().trim();
    return text == 'null' ? '' : text;
  }

  /// 변경 하나의 식별 키. 같은 변경이 두 경로(WebSocket 기록 수신함과 결과 조회·대기 변경)로 와도 같은 키가 된다.
  /// 신고번호(중복군은 group_id)가 없으면 null — 그런 항목은 서로 합치지 않는다.
  static String? changeKeyOf(Map<String, dynamic>? change) {
    if (change == null) return null;
    final kind = _text(change['notification_kind']);
    if (kind == 'duplicate') {
      final groupId = _text(change['group_id']);
      if (groupId.isEmpty) return null;
      return [
        'duplicate',
        groupId,
        _text(change['duplicate_change_type']),
        _text(change['status']),
        _text(change['representative_id']),
        _text(change['member_count']),
      ].join('\u001f');
    }
    final number = normalizeReportNumber(change['신고번호']?.toString());
    if (number.isEmpty) return null;
    return [
      'report',
      number,
      _text(change['change_type']),
      _text(change['처리상태']),
      _text(change['synced_at']),
      _text(change['답변일']),
    ].join('\u001f');
  }

  static String? _itemKey(NotificationItem item) {
    if (item.kind != NotificationItemKind.report &&
        item.kind != NotificationItemKind.duplicate) {
      return null;
    }
    final extra = item.extraData;
    if (extra == null || extra.isEmpty) return null;
    if (item.kind == NotificationItemKind.duplicate &&
        _text(extra['notification_kind']).isEmpty) {
      return changeKeyOf({...extra, 'notification_kind': 'duplicate'});
    }
    return changeKeyOf(extra);
  }

  String _reportNumberForItem(NotificationItem item) {
    final reportNumber = normalizeReportNumber(item.reportNumber);
    if (reportNumber.isNotEmpty) return reportNumber;
    return extractReportNumberFromPayload(item.extraData);
  }

  static String _uniqueTag() => newUuidV4().substring(0, 8);

  // ── 읽기 ──────────────────────────────────────────────────────────────────

  Future<void> load({bool notify = true}) => _serialized(() async {
    final changed = await _loadLocked();
    if (changed && notify) _notify();
  });

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _serialized(() async {
      if (!_loaded) await _loadLocked();
    });
  }

  Future<void> _ensureLoadedLocked() async {
    if (!_loaded) await _loadLocked();
  }

  Future<SharedPreferences> _reloadedPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // WsService 가 수신함에 넣은 것 반영
    return prefs;
  }

  /// 저장본과 수신함을 반영한다. 반환: 목록이 바뀌었는지.
  Future<bool> _loadLocked() async {
    final prefs = await _reloadedPrefs();
    final raw = prefs.getString(_key);
    var changed = false;
    if (!_loaded) {
      _items = _withUniqueIds(_decode(raw));
      _storedRaw = raw;
      _loaded = true;
      changed = true;
    } else if (raw != _storedRaw) {
      // 이 키는 이 객체만 쓴다. 그래도 다른 엔진이 썼다면 저장본을 따르되, 아직 저장 못 한 메모리 항목은 지키고 합친다.
      final stored = _withUniqueIds(_decode(raw));
      if (_dirty) {
        final known = _items.map((i) => i.id).toSet();
        _items = [..._items, ...stored.where((i) => !known.contains(i.id))];
      } else {
        _items = stored;
      }
      _storedRaw = raw;
      changed = true;
    }
    final inboxKeys = _mergeInbox(prefs);
    if (inboxKeys.isNotEmpty) changed = true;
    if (_dirty || inboxKeys.isNotEmpty) await _persist(prefs, inboxKeys);
    return changed;
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

  /// 이 변경 자체를 이미 읽었는지. 같은 신고의 다른(뒤에 온) 변경은 읽은 것으로 치지 않는다(SQ-B01).
  bool isPayloadRead(Map<String, dynamic>? payload) {
    if ((payload?['notification_kind']?.toString() ?? '') == 'duplicate') {
      return false;
    }
    final key = changeKeyOf(payload);
    if (key == null) return false;
    var matched = false;
    for (final item in _items) {
      if (_itemKey(item) != key) continue;
      if (!item.isRead) return false;
      matched = true;
    }
    return matched;
  }

  // ── 읽음 표시 (저장은 몰아서) ────────────────────────────────────────────

  Future<void> markRead(String id) async {
    final changed = await _serialized(() async {
      await _ensureLoadedLocked();
      final idx = _items.indexWhere((i) => i.id == id);
      if (idx < 0 || _items[idx].isRead) return false;
      _items = List.of(_items)..[idx] = _items[idx].copyWith(isRead: true);
      _dirty = true;
      return true;
    });
    if (!changed) return;
    _notify();
    await _flush();
  }

  /// 상세 시트를 열면 그 신고의 기존 기록만 읽음으로 한다. 뒤에 올 다른 변경에는 영향이 없다.
  Future<void> markReportRead(String reportNumber) async {
    final normalized = normalizeReportNumber(reportNumber);
    if (normalized.isEmpty) return;
    final changed = await _serialized(() async {
      await _ensureLoadedLocked();
      var changed = false;
      _items = _items.map((item) {
        if (_reportNumberForItem(item) == normalized && !item.isRead) {
          changed = true;
          return item.copyWith(isRead: true);
        }
        return item;
      }).toList();
      if (changed) _dirty = true;
      return changed;
    });
    if (!changed) return;
    _notify();
    await _flush();
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
    final changed = await _serialized(() async {
      await _ensureLoadedLocked();
      if (_items.every((i) => i.isRead)) return false;
      _items = _items.map((i) => i.copyWith(isRead: true)).toList();
      _dirty = true;
      return true;
    });
    if (!changed) return;
    _notify();
    await _flush();
  }

  /// 연달아 들어온 읽음 표시를 한 번의 저장으로 몬다. 큐에 이미 저장이 기다리고 있으면 그것을 같이 기다린다.
  Future<void> _flush() => _pendingFlush ??= _serialized(() async {
    _pendingFlush = null;
    if (!_dirty) return;
    final prefs = await _reloadedPrefs();
    final inboxKeys = _mergeInbox(prefs);
    await _persist(prefs, inboxKeys);
    if (inboxKeys.isNotEmpty) _notify();
  });

  Future<void> clearAll() => _serialized(() async {
    _items = [];
    _loaded = true;
    _dirty = false;
    final prefs = await _reloadedPrefs();
    await prefs.remove(_key);
    _storedRaw = null;
    await PrefsInbox.remove(
      prefs,
      PrefsInbox.read(prefs, PrefsInbox.history).map((e) => e.key),
    );
    _notify();
  });

  // ── 추가 (반환 전에 영속 저장) ───────────────────────────────────────────

  Future<void> addFromServerResults(
    List<Map<String, dynamic>> serverData, {
    bool isMobileTriggered = false,
  }) => _serialized(() async {
    final prefs = await _prepareLocked();
    final inboxKeys = _mergeInbox(prefs);
    final added = _addChangesLocked(
      serverData,
      isMobileTriggered: isMobileTriggered,
    );
    if (added == 0 && inboxKeys.isEmpty && !_dirty) return;
    await _persist(prefs, inboxKeys);
    _notify();
  });

  /// 대기 변경 가운데 아직 읽지 않은 것을 기록에 넣고 저장까지 마친 뒤 돌려준다.
  /// 읽음 판정과 추가가 한 작업 안에서 일어나 그 사이 다른 읽기·쓰기가 끼지 않는다.
  /// 중복군 변경은 늘 돌려준다(예전과 같음). 저장이 실패하면 throw — 호출자는 대기열을 ack 하지 않는다.
  Future<List<Map<String, dynamic>>> recordPendingChanges(
    List<Map<String, dynamic>> changes, {
    int? preferredTabIndexIfUnread,
  }) => _serialized(() async {
    final prefs = await _prepareLocked();
    final inboxKeys = _mergeInbox(prefs);
    final readByKey = <String, bool>{};
    for (final item in _items) {
      final key = _itemKey(item);
      if (key == null) continue;
      readByKey[key] = (readByKey[key] ?? true) && item.isRead;
    }
    final unread = changes.where((change) {
      final kind = change['notification_kind']?.toString() ?? 'report';
      if (kind == 'duplicate') return true;
      final key = changeKeyOf(change);
      if (key == null) return true;
      return !(readByKey[key] ?? false);
    }).toList();
    final added = unread.isEmpty ? 0 : _addChangesLocked(unread);
    final moveTab =
        unread.isNotEmpty &&
        preferredTabIndexIfUnread != null &&
        _preferredTabIndex != preferredTabIndexIfUnread;
    if (moveTab) _preferredTabIndex = preferredTabIndexIfUnread;
    if (added > 0 || inboxKeys.isNotEmpty || _dirty) {
      await _persist(prefs, inboxKeys);
    }
    if (added > 0 || inboxKeys.isNotEmpty || moveTab) _notify();
    return unread;
  });

  Future<void> addRatingBatchResult(RatingBatchResult result) =>
      _serialized(() async {
        final prefs = await _prepareLocked();
        final inboxKeys = _mergeInbox(prefs);
        _items = [
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
          ..._items,
        ];
        _dirty = true;
        await _persist(prefs, inboxKeys);
        _notify();
      });

  /// Client 모드: 서버 변경 결과를 먼저 받아 기록에 영속 저장한 뒤에야 한 번만 읽히는 완료 신호를 소비한다(SQ-B04).
  /// 화면이 닫혀도 이 객체가 끝까지 처리한다. 겹친 호출은 진행 중인 확인을 같이 기다린다.
  Future<ServerCrawlPoll> pollServerCrawlResults({
    required Future<List<Map<String, dynamic>>> Function() fetchResults,
    required Future<Map<String, dynamic>> Function() consumeDone,
  }) => _serverPoll ??= _pollServer(
    fetchResults,
    consumeDone,
  ).whenComplete(() => _serverPoll = null);

  Future<ServerCrawlPoll> _pollServer(
    Future<List<Map<String, dynamic>>> Function() fetchResults,
    Future<Map<String, dynamic>> Function() consumeDone,
  ) async {
    const failed = (ok: false, doneChangedCount: null);
    final List<Map<String, dynamic>> results;
    try {
      results = await fetchResults();
    } catch (e) {
      debugPrint('[알림 기록] 서버 변경 결과 조회 실패 — 완료 신호는 남겨 두고 다음에 다시 확인: $e');
      return failed;
    }
    if (results.isNotEmpty) {
      try {
        await addFromServerResults(results);
        setPreferredTabIndex(1);
      } catch (e) {
        // 항목은 메모리에 남아 다음 저장 때 다시 기록된다. 완료 신호는 소비하지 않는다.
        debugPrint('[알림 기록] 서버 변경 결과 저장 실패 — 다음 저장 때 다시 시도: $e');
        return failed;
      }
    }
    final Map<String, dynamic> done;
    try {
      done = await consumeDone();
    } catch (e) {
      debugPrint('[알림 기록] 서버 완료 신호 확인 실패 — 다음에 다시 확인: $e');
      return failed;
    }
    if (done['done'] != true) return (ok: true, doneChangedCount: null);
    final changedCount = (done['changed_count'] as num?)?.toInt() ?? 0;
    setPreferredTabIndex(1);
    if (results.isEmpty && changedCount == 0) {
      try {
        await addFromServerResults(const []); // "크롤링 완료 — 변경 없음" 기록
      } catch (e) {
        debugPrint('[알림 기록] 크롤링 완료 기록 저장 실패 — 다음 저장 때 다시 시도: $e');
        return (ok: false, doneChangedCount: changedCount);
      }
    }
    return (ok: true, doneChangedCount: changedCount);
  }

  // ── 내부 ──────────────────────────────────────────────────────────────────

  Future<SharedPreferences> _prepareLocked() async {
    await _ensureLoadedLocked();
    return _reloadedPrefs();
  }

  /// 변경 목록을 기록 항목으로 만들어 앞에 붙인다. 반환: 추가한 수. 큐 안에서만 부른다.
  int _addChangesLocked(
    List<Map<String, dynamic>> serverData, {
    bool isMobileTriggered = false,
  }) {
    final now = DateTime.now();
    final ms = now.millisecondsSinceEpoch;
    final ts =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final List<NotificationItem> newItems = [];

    if (serverData.isEmpty) {
      newItems.add(
        NotificationItem(
          id: '${ms}_${_uniqueTag()}',
          kind: NotificationItemKind.crawl,
          title: isMobileTriggered ? '📱 크롤링 완료' : '🖥️ 크롤링 완료',
          body: '변경된 신고건이 없습니다.',
          reportNumber: '',
          timestamp: ts,
          isRead: false,
        ),
      );
    } else {
      final existingKeys = <String>{for (final item in _items) ?_itemKey(item)};
      // 한 묶음 안에서도 ID가 겹치지 않게 순번과 임의 꼬리를 붙인다(SQ-B12).
      final tag = _uniqueTag();

      // 기록은 최대 200개만 보관한다. 대량 변경 때 수천 개 객체를 먼저 만드는 일을 피한다.
      var index = 0;
      for (final r in serverData.take(_maxItems)) {
        final i = index++;
        final key = changeKeyOf(r);
        if (key != null && !existingKeys.add(key)) continue;
        final notificationKind = r['notification_kind']?.toString() ?? 'report';
        if (notificationKind == 'duplicate') {
          final groupId = r['group_id']?.toString() ?? '';
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
              id: '${ms}_${i}_${groupId.isEmpty ? 'duplicate' : groupId}_$tag',
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
          continue;
        }

        final rnum = r['신고번호']?.toString() ?? '';
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
            id: '${ms}_${i}_${rnum}_$tag',
            kind: NotificationItemKind.report,
            title: '$titleIcon $name',
            body: lines.join('\n'),
            reportNumber: rnum,
            timestamp: ts,
            isRead: false,
            extraData: Map<String, dynamic>.from(r),
          ),
        );
      }
    }

    if (newItems.isEmpty) return 0;
    _items = [...newItems, ..._items];
    _dirty = true;
    return newItems.length;
  }

  /// 백그라운드 서비스(Kotlin WsService)가 수신함에 넣은 항목을 메모리 목록 앞에 합친다. 반환: 합친 수신함 키.
  /// 같은 변경이 이미 기록에 있으면(결과 조회로 먼저 들어온 경우) 다시 넣지 않는다.
  List<String> _mergeInbox(SharedPreferences prefs) {
    final inbox = PrefsInbox.read(prefs, PrefsInbox.history);
    if (inbox.isEmpty) return const [];
    final ids = _items.map((i) => i.id).toSet();
    final keys = <String>{for (final item in _items) ?_itemKey(item)};
    for (final entry in inbox) {
      // 오래된 수신함부터 앞에 붙인다 → 가장 새 것이 맨 앞. 한 수신함 안은 이미 새 것부터.
      final fresh = <NotificationItem>[];
      final entryIds = <String>{};
      for (final raw in entry.items) {
        var item = NotificationItem.fromJson(raw);
        // 이미 합친 수신함(지우기 전에 멈춘 경우)은 건너뛴다.
        if (ids.contains(item.id) && !entryIds.contains(item.id)) continue;
        final key = _itemKey(item);
        if (key != null && keys.contains(key)) continue;
        // 예전 서비스가 한 묶음 안에서 같은 ID를 만든 경우 — 버리지 않고 ID만 고유하게.
        if (!entryIds.add(item.id)) {
          item = item.copyWith(id: '${item.id}_${_uniqueTag()}');
        }
        ids.add(item.id);
        if (key != null) keys.add(key);
        fresh.add(item);
      }
      if (fresh.isNotEmpty) _items = [...fresh, ..._items];
    }
    _dirty = true;
    return inbox.map((e) => e.key).toList();
  }

  /// 알림 기록 키는 이 앱만 쓴다. 백그라운드 서비스(Kotlin WsService)는 새 알림을 수신함 키에 넣고,
  /// 여기서 합친 뒤 합친 키만 지운다(같은 키를 두 쪽이 읽고-고쳐-쓰며 서로 덮던 문제 — M-29/M-31).
  /// 실패하면 throw 하고 [_dirty] 를 남겨 다음 작업이 다시 저장한다.
  Future<void> _persist(
    SharedPreferences prefs,
    List<String> mergedInboxKeys,
  ) async {
    if (_items.length > _maxItems) _items = _items.sublist(0, _maxItems);
    final encoded = jsonEncode(_items.map((i) => i.toJson()).toList());
    if (encoded != _storedRaw) {
      if (!await prefs.setString(_key, encoded)) {
        throw StateError('notification history handoff failed');
      }
      _storedRaw = encoded;
    }
    _dirty = false;
    if (mergedInboxKeys.isNotEmpty) {
      await PrefsInbox.remove(prefs, mergedInboxKeys);
    }
  }

  static List<NotificationItem> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((i) => NotificationItem.fromJson(i as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 예전 버전이 저장한 겹친 ID(`밀리초_신고번호` 에서 번호가 비었던 경우 등)를 고유하게 바꾼다.
  /// 그대로 두면 읽음 표시가 첫 항목에만 적용된다(SQ-B12). 바뀌면 다음 저장 때 기록된다.
  List<NotificationItem> _withUniqueIds(List<NotificationItem> items) {
    final seen = <String>{};
    var renamed = false;
    final result = <NotificationItem>[];
    for (final item in items) {
      if (seen.add(item.id)) {
        result.add(item);
        continue;
      }
      var n = 1;
      var id = '${item.id}_dup$n';
      while (!seen.add(id)) {
        id = '${item.id}_dup${++n}';
      }
      result.add(item.copyWith(id: id));
      renamed = true;
    }
    if (renamed) _dirty = true;
    return result;
  }
}
