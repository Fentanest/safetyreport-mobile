import 'package:flutter_test/flutter_test.dart';
import '../../scripts/check_raw_backfill.dart' as offline;
import 'package:safetyreport/community/raw_backfill.dart';

void main() {
  test('shared PC/mobile backfill traces', () async {
    expect(await offline.verifyBackfillCases(), equals(43));
  });
  test('a fresh grant keeps the run; a new dataset resets it', () async {
    // Policy: the run identity is dataset + account + local database. A renewed grant (same lineage),
    // a new writer or a new parser generation never re-sends everything (mobile-review 11).
    final backend = offline.FixtureBackend();
    Map<String, dynamic>? saved;
    final runner = RawBackfill(
      load: () async => saved,
      save: (m, s) async {
        saved = m;
      },
      backend: backend,
    );
    final first = await runner.run(budget: 1);
    expect(first!['cursor'], 1);
    backend.identity['consent_grant_id'] = 'fresh-grant';
    final next = await runner.run(budget: 1);
    expect(next!['consent_grant_id'], 'fresh-grant');
    expect(next['run_id'], first['run_id']);
    expect(next['cursor'], 2);
    backend.identity['local_dataset_id'] = 'restored-database';
    final restarted = await runner.run(budget: 1);
    expect(restarted!['run_id'], isNot(first['run_id']));
    expect(restarted['cursor'], 1);
  });
}
