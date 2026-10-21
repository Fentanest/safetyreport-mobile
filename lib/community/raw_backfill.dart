import 'dart:convert';
import 'dart:math';

class BackfillPaused implements Exception {
  BackfillPaused(this.reason, {this.retrySeconds = 300});
  final String reason;
  final int retrySeconds;
}

class BackfillCancelled implements Exception {}

class BackfillBlocked implements Exception {
  BackfillBlocked(this.reason);
  final String reason;
}

abstract class RawBackfillBackend {
  Future<Map<String, dynamic>?> scope();
  Future<bool> current(Map<String, dynamic> scope);
  Future<bool> optimizationReady();
  Future<Map<String, dynamic>> inventory();
  Future<List<String>> localIds();
  Future<List<String>> eligibleIds();
  Future<Map<String, dynamic>> prepare(String id);
  Future<String?> enqueue(String id, String run);
  Future<String> receipt(String id, String event);
  Future<void> wakeUpload();
}

/// 업로드 단계의 영수증 조회를 한 번에 묶을 수 있는 backend(선택). 없으면 항목마다 [RawBackfillBackend.receipt].
abstract class BatchedReceipts {
  Future<void> prefetchReceipts(Iterable<String> events);
}

abstract class BackfillItems {
  Future<void> reset(String run, Map<String, Map<String, dynamic>> items);
  Future<void> loadLegacy(String run, Map<String, dynamic> items);
  Future<void> retry(String run);
  Future<List<(int, String, Map<String, dynamic>)>> page(
    String run,
    int cursor,
    int limit,
  );
  Future<List<(String, Map<String, dynamic>)>> queued(String run, int limit);
  Future<void> put(String run, String id, Map<String, dynamic> item);
  Future<int> size(String run);
  Future<Map<String, int>> summary(String run);
}

Map<String, dynamic> _copy(Map value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

class MemoryBackfillItems implements BackfillItems {
  Map<String, Map<String, dynamic>> items = {};
  @override
  Future<void> reset(
    String run,
    Map<String, Map<String, dynamic>> items,
  ) async {
    this.items = items;
  }

  @override
  Future<void> loadLegacy(String run, Map<String, dynamic> items) async {
    this.items = {for (final e in items.entries) e.key: _copy(e.value as Map)};
  }

  @override
  Future<void> retry(String run) async {
    for (final item in items.values) {
      if (item['state'] == 'hold') {
        item.addAll({'state': 'pending', 'attempts': 0, 'event_id': null});
      }
    }
  }

  @override
  Future<List<(int, String, Map<String, dynamic>)>> page(
    String run,
    int cursor,
    int limit,
  ) async {
    final rows = items.entries.toList();
    return [
      for (var p = cursor; p < rows.length && p < cursor + limit; p++)
        (p, rows[p].key, _copy(rows[p].value)),
    ];
  }

  @override
  Future<List<(String, Map<String, dynamic>)>> queued(
    String run,
    int limit,
  ) async => items.entries
      .where((e) => e.value['state'] == 'queued')
      .take(limit)
      .map((e) => (e.key, _copy(e.value)))
      .toList();
  @override
  Future<void> put(String run, String id, Map<String, dynamic> item) async {
    items[id] = _copy(item);
  }

  @override
  Future<int> size(String run) async => items.length;
  @override
  Future<Map<String, int>> summary(String run) async =>
      summarizeBackfill(items.values);
  Map<String, dynamic> get holds => {
    for (final e in items.entries)
      if (e.value['state'] == 'hold')
        e.key: {
          'reason': e.value['error'] ?? 'upload_rejected',
          'attempts': e.value['attempts'],
        },
  };
}

Map<String, int> summarizeBackfill(Iterable<Map<String, dynamic>> items) {
  final s = <String, int>{
    for (final k in [
      'total',
      'raw_unavailable',
      'available',
      'sent',
      'filled',
      'unfilled',
      'missing_reports',
      'holds',
      'unfinished',
    ])
      k: 0,
  };
  for (final i in items) {
    final eligible = i['eligible'] == true && i['state'] != 'not_eligible';
    if (eligible) {
      s['total'] = s['total']! + 1;
    }
    if (eligible && i['state'] == 'raw_unavailable') {
      s['raw_unavailable'] = s['raw_unavailable']! + 1;
    }
    if (eligible && i['state'] == 'stored') {
      s['sent'] = s['sent']! + 1;
    }
    for (final key in ['filled', 'unfilled']) {
      s[key] = s[key]! + (i[key] as num? ?? 0).toInt();
    }
    if (i['was_missing'] == true) {
      s['missing_reports'] = s['missing_reports']! + 1;
    }
    if (i['state'] == 'hold') {
      s['holds'] = s['holds']! + 1;
    }
    if (!['stored', 'raw_unavailable', 'not_eligible'].contains(i['state'])) {
      s['unfinished'] = s['unfinished']! + 1;
    }
  }
  s['available'] = s['total']! - s['raw_unavailable']!;
  return s;
}

/// The same bounded phases, completion and retry rules as PC RawBackfill.
class RawBackfill {
  RawBackfill({
    required this.load,
    required this.save,
    required this.backend,
    this.items,
    this.shouldYield,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final Future<Map<String, dynamic>?> Function() load;
  final Future<void> Function(Map<String, dynamic>, Map<String, dynamic>) save;
  final RawBackfillBackend backend;
  final BackfillItems? items;
  final bool Function()? shouldYield;
  final DateTime Function() now;
  double get seconds => now().millisecondsSinceEpoch / 1000;
  Future<Map<String, dynamic>?> run({
    int budget = 1000,
    bool retryHolds = false,
  }) async {
    final b = backend, scope = await backend.scope();
    if (scope == null || !await b.current(scope)) {
      return null;
    }
    var m = await load();
    final repo = items ?? MemoryBackfillItems();
    if (m == null || ['local_dataset_id'].any((k) => m![k] != scope[k])) {
      m = <String, dynamic>{
        'contract': 'v2',
        ...scope,
        'run_id':
            '${now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x100000000)}',
        'state': 'waiting_optimize',
        'phase': 'listing',
        'listing_complete': false,
        'cursor': 0,
        'stats': <String, dynamic>{},
        'holds': <String, dynamic>{},
        'failures': 0,
        'next_attempt_at': 0,
      };
      await repo.reset(m['run_id'] as String, {});
    } else if (m['items'] is Map) {
      await repo.loadLegacy(
        m['run_id'] as String,
        (m['items'] as Map).cast<String, dynamic>(),
      );
      m['listing_complete'] = m['listing_complete'] ?? m['phase'] != 'listing';
    }
    final marker = m, run = marker['run_id'] as String;
    marker.addAll(scope);
    if (retryHolds) {
      await repo.retry(run);
      marker.addAll({'failures': 0, 'next_attempt_at': 0});
      if (marker['phase'] != 'listing' && marker['listing_complete'] == true) {
        marker.addAll({'phase': 'filling', 'cursor': 0});
      }
    }
    Future<void> publish() async {
      if (!await b.current(scope)) {
        throw BackfillCancelled();
      }
      final stats = await repo.summary(run);
      marker['stats'] = {
        for (final e in stats.entries)
          if (e.key != 'unfinished') e.key: e.value,
      };
      if (repo is MemoryBackfillItems) {
        marker['holds'] = repo.holds;
        marker['items'] = _copy(repo.items);
      } else {
        marker['holds'] = stats['holds'];
        marker.remove('items');
      }
      await save(_copy(marker), scope);
    }

    if (marker['state'] == 'done' && !retryHolds) {
      return marker;
    }
    try {
      if (seconds < (marker['next_attempt_at'] as num? ?? 0)) {
        return marker;
      }
      marker.remove('reason');
      marker['next_attempt_at'] = 0;
      if (!await b.optimizationReady()) {
        marker['state'] = 'waiting_optimize';
        await publish();
        return marker;
      }
      if (marker['phase'] == 'listing' || marker['listing_complete'] != true) {
        marker.addAll({'phase': 'listing', 'state': 'listing'});
        await publish();
        final inventory = await b.inventory();
        if (inventory['list_ok'] != true) {
          throw BackfillPaused('list_incomplete');
        }
        final existing = (await b.localIds()).toSet(),
            eligible = (await b.eligibleIds()).toSet();
        final missing = (inventory['ids'] as List)
            .cast<String>()
            .toSet()
            .difference(existing);
        final remoteEligible = (inventory['eligible_ids'] as List? ?? [])
            .cast<String>()
            .toSet();
        final ids = eligible.union(missing).toList()..sort();
        await repo.reset(run, {
          for (final id in ids)
            id: <String, dynamic>{
              'state': 'pending',
              'attempts': 0,
              'eligible': eligible.contains(id) || remoteEligible.contains(id),
              'was_missing': missing.contains(id),
            },
        });
        marker.addAll({
          'phase': 'filling',
          'state': 'filling',
          'cursor': 0,
          'listing_complete': true,
        });
        await publish();
      }
      if (marker['phase'] == 'filling') {
        marker['state'] = 'filling';
        for (final (index, id, item) in await repo.page(
          run,
          (marker['cursor'] as num).toInt(),
          budget,
        )) {
          if (shouldYield?.call() == true) {
            break;
          }
          if ([
            'stored',
            'raw_unavailable',
            'not_eligible',
            'hold',
            'queued',
          ].contains(item['state'])) {
            marker['cursor'] = index + 1;
            continue;
          }
          if (!await b.current(scope)) {
            throw BackfillCancelled();
          }
          try {
            item.addAll(await b.prepare(id));
            if (!await b.current(scope)) {
              throw BackfillCancelled();
            }
            if (item['eligible'] != true) {
              item['state'] = 'not_eligible';
            } else if (item['raw_unavailable'] == true) {
              item['state'] = 'raw_unavailable';
            } else {
              item['event_id'] = await b.enqueue(id, run);
              if (item['event_id'] == null) {
                throw StateError('raw_event_not_created');
              }
              item['state'] = 'queued';
            }
            marker['failures'] = 0;
            marker['cursor'] = index + 1;
          } on BackfillBlocked catch (e) {
            item.addAll({
              'state': 'not_eligible',
              'eligible': false,
              'error': e.reason,
            });
            marker['cursor'] = index + 1;
          } on BackfillPaused {
            rethrow;
          } on BackfillCancelled {
            rethrow;
          } catch (e) {
            item['attempts'] = (item['attempts'] as int) + 1;
            marker['failures'] = (marker['failures'] as int) + 1;
            item['error'] = e.runtimeType.toString();
            if (item['attempts'] >= 3) {
              item['state'] = 'hold';
              marker['cursor'] = index + 1;
            } else {
              marker['cursor'] = index;
            }
            await repo.put(run, id, item);
            if (marker['failures'] >= 5) {
              throw BackfillPaused('consecutive_failures');
            }
            if (item['attempts'] < 3) {
              break;
            }
          }
          await repo.put(run, id, item);
        }
        if (marker['cursor'] >= await repo.size(run)) {
          marker.addAll({'phase': 'uploading', 'state': 'uploading'});
        }
      }
      if (marker['phase'] == 'uploading') {
        final queued = await repo.queued(run, budget);
        if (b is BatchedReceipts) {
          await (b as BatchedReceipts).prefetchReceipts([
            for (final (_, item) in queued)
              if (item['event_id'] is String) item['event_id'] as String,
          ]);
        }
        for (final (id, item) in queued) {
          if (shouldYield?.call() == true) {
            break;
          }
          final result = await b.receipt(id, item['event_id'] as String);
          if (result == 'stored') {
            item['state'] = 'stored';
          } else if (result == 'blocked') {
            item.addAll({
              'state': 'not_eligible',
              'eligible': false,
              'error': 'upload_rejected',
            });
          } else if (result == 'retry' || result == 'rebind') {
            item.addAll({
              'state': 'pending',
              'attempts': result == 'rebind'
                  ? 0
                  : (item['attempts'] as int) + 1,
            });
            if (item['attempts'] >= 3) {
              item.addAll({
                'state': 'not_eligible',
                'eligible': false,
                'error': 'upload_rejected',
              });
            } else {
              marker.addAll({'phase': 'filling', 'cursor': 0});
            }
          }
          await repo.put(run, id, item);
        }
        final stats = await repo.summary(run),
            complete =
                marker['listing_complete'] == true && stats['unfinished'] == 0;
        marker['state'] = complete
            ? 'done'
            : stats['holds']! > 0
            ? 'holds'
            : marker['phase'];
        if (!complete) {
          await b.wakeUpload();
        }
      }
      await publish();
      return marker;
    } on BackfillPaused catch (e) {
      marker.addAll({
        'state': 'paused',
        'reason': e.reason,
        'next_attempt_at': seconds + e.retrySeconds,
      });
      await publish();
      return marker;
    } on BackfillCancelled {
      return null;
    }
  }
}
