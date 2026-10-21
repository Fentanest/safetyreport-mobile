import 'dart:convert';
import 'dart:io';
import 'package:safetyreport/community/raw_backfill.dart';
import 'package:safetyreport/community/client_server_policy.dart';

class FixtureBackend implements RawBackfillBackend {
  Map<String, dynamic> identity = {
    'local_dataset_id': 'local',
    'contributor_fingerprint': 'synthetic',
    'dataset_key': 'dataset',
    'consent_grant_id': 'grant',
    'parser_target': 'mobile-parser-13',
    'connection_id': 'connection',
    'writer_epoch': 1,
  };
  bool optimized = true, listOk = true;
  Set<String> unavailable = {}, fail = {}, auth = {};
  Map<String, dynamic> receipts = {};
  final enqueued = <String>[];
  void configure(Map action) {
    if (action.containsKey('optimized')) {
      optimized = action['optimized'] as bool;
    }
    if (action.containsKey('list_ok')) listOk = action['list_ok'] as bool;
    if (action.containsKey('fail')) {
      fail = (action['fail'] as List).cast<String>().toSet();
    }
    if (action.containsKey('auth')) {
      auth = (action['auth'] as List).cast<String>().toSet();
    }
    if (action.containsKey('unavailable')) {
      unavailable = (action['unavailable'] as List).cast<String>().toSet();
    }
    if (action.containsKey('receipts')) {
      receipts = (action['receipts'] as Map).cast<String, dynamic>();
    }
    if (action.containsKey('dataset')) {
      identity['local_dataset_id'] = action['dataset'];
    }
  }

  @override
  Future<Map<String, dynamic>?> scope() async => Map.from(identity);
  @override
  Future<bool> current(Map<String, dynamic> scope) async =>
      identity.entries.every((e) => scope[e.key] == e.value);
  @override
  Future<bool> optimizationReady() async => optimized;
  @override
  Future<Map<String, dynamic>> inventory() async => {
    'list_ok': listOk,
    'ids': ['A', 'B', 'C'],
    'eligible_ids': ['A', 'B', 'C'],
  };
  @override
  Future<List<String>> localIds() async => ['A', 'B'];
  @override
  Future<List<String>> eligibleIds() async => ['A', 'B'];
  @override
  Future<Map<String, dynamic>> prepare(String id) async {
    if (auth.contains(id)) throw BackfillPaused('official_login_required');
    if (fail.contains(id)) throw StateError('synthetic_retry');
    return {
      'eligible': true,
      'raw_unavailable': unavailable.contains(id),
      'filled': unavailable.contains(id) ? 0 : 1,
      'unfilled': unavailable.contains(id) ? 1 : 0,
    };
  }

  @override
  Future<String?> enqueue(String id, String run) async {
    enqueued.add(id);
    return 'event-$id';
  }

  @override
  Future<String> receipt(String id, String event) async =>
      receipts[id] as String? ?? 'pending';
  @override
  Future<void> wakeUpload() async {}
}

Future<int> verifyBackfillCases() async {
  final fixture =
      jsonDecode(
            File('test/fixtures/raw_backfill_cases.json').readAsStringSync(),
          )
          as Map;
  var checks = 0;
  for (final row in fixture['cases'] as List) {
    final backend = FixtureBackend()..configure(row['initial'] as Map);
    Map<String, dynamic>? saved;
    var time = 1000;
    for (final action in row['actions'] as List) {
      backend.configure(action as Map);
      time += (action['advance'] as num? ?? 0).toInt();
      final runner = RawBackfill(
        load: () async => saved == null
            ? null
            : (jsonDecode(jsonEncode(saved)) as Map).cast<String, dynamic>(),
        save: (value, scope) async {
          saved = value;
        },
        backend: backend,
        now: () => DateTime.fromMillisecondsSinceEpoch(time * 1000),
      );
      final result = await runner.run(
        budget: (action['budget'] as num? ?? 20).toInt(),
        retryHolds: action['retry_holds'] == true,
      );
      for (final expected in (action['expect'] as Map).entries) {
        final actual =
            [
              'total',
              'available',
              'raw_unavailable',
              'sent',
              'filled',
              'unfilled',
              'holds',
            ].contains(expected.key)
            ? (result!['stats'] as Map)[expected.key]
            : result![expected.key];
        if (actual != expected.value) {
          throw StateError(
            '${row['name']}: ${expected.key}: $actual != ${expected.value}: ${jsonEncode(result)}',
          );
        }
        checks++;
      }
    }
  }
  for (final pair in <(Map<String, dynamic>?, bool)>[
    (null, false),
    ({'can_enter': true}, true),
    ({'can_local': true, 'can_enter': false}, true),
    (
      {'state': 'kakao_required', 'can_local': false, 'can_enter': false},
      false,
    ),
    ({'can_enter': 'true'}, false),
  ]) {
    if (serverConsentAllows(pair.$1) != pair.$2) {
      throw StateError('Client server gate policy');
    }
    checks++;
  }
  return checks;
}

Future<void> main() async {
  stdout.writeln(
    'PASS: ${await verifyBackfillCases()} shared backfill trace assertions',
  );
}
