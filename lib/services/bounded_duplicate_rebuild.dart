part of 'duplicate_projection_service.dart';

/// Derived, disposable SQLite data. No raw payloads or Report objects retained.
/// Source invalidation triggers also run for writers on other connections.
class _BoundedDuplicateRebuild {
  static const input = 'sr_duplicate_input_v1';
  static const meta = 'sr_duplicate_revision_v1';
  static const pageSize = 128;
  static final _pending = Expando<Future<Map<String, dynamic>>>();

  static Future<Map<String, dynamic>> run(
    Database db, {
    required bool trackChanges,
  }) async {
    // Calls with different notification requirements must each observe changes.
    while (_pending[db] != null) {
      try {
        await _pending[db];
      } catch (_) {
        /* next call can retry */
      }
    }
    final work = _rebuild(db, trackChanges);
    _pending[db] = work;
    try {
      return await work;
    } finally {
      _pending[db] = null;
    }
  }

  static Future<void> _schema(Database db) async {
    await db.rawQuery('PRAGMA journal_mode=WAL');
    await db.transaction((t) async {
      await t.execute('''CREATE TABLE IF NOT EXISTS $input (
        ID TEXT PRIMARY KEY, ordinal INTEGER NOT NULL,
        payload_hash TEXT NOT NULL, legacy_hash TEXT NOT NULL,
        field_key TEXT NOT NULL, car TEXT NOT NULL, category TEXT NOT NULL,
        entry_value TEXT NOT NULL, report_number TEXT NOT NULL,
        fine_rank INTEGER NOT NULL, status_rank INTEGER NOT NULL,
        answer_rank INTEGER NOT NULL, synced_rank INTEGER NOT NULL
      )''');
      if ((await t.rawQuery('SELECT 1 FROM $input LIMIT 1')).isEmpty) {
        await t.execute('DROP INDEX IF EXISTS sr_duplicate_hash_v1');
      }
      await t.execute(
        'CREATE TABLE IF NOT EXISTS $meta (id INTEGER PRIMARY KEY, revision INTEGER NOT NULL)',
      );
      await addColumnIfMissing(
        t,
        meta,
        'built_revision',
        'INTEGER NOT NULL DEFAULT -1',
      );
      await t.execute('INSERT OR IGNORE INTO $meta(id,revision) VALUES(1,0)');
      // SQLite snapshot copying may compact rowids. Ordering is derived from
      // the current source, never a cached ordinal from a different file.
      await t.execute(
        'DELETE FROM $input WHERE NOT EXISTS(SELECT 1 FROM reports r WHERE r.ID=$input.ID)',
      );
      await t.execute(
        'UPDATE $input SET ordinal=(SELECT rowid FROM reports r WHERE r.ID=$input.ID) WHERE ordinal<>(SELECT rowid FROM reports r WHERE r.ID=$input.ID)',
      );
      for (final table in ['reports', 'report_raw']) {
        for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
          final deleted = operation == 'DELETE';
          await t.execute(
            '''CREATE TRIGGER IF NOT EXISTS sr_dup_${table}_${operation.toLowerCase()}_v1
            AFTER $operation ON $table BEGIN
              DELETE FROM $input WHERE ID=${deleted ? 'OLD' : 'NEW'}.ID
                ${operation == 'UPDATE' ? 'OR ID=OLD.ID' : ''};
              UPDATE $meta SET revision=revision+1 WHERE id=1;
            END''',
          );
        }
      }
      for (final table in [
        'duplicate_decision',
        'duplicate_group',
        'duplicate_member',
      ]) {
        for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
          await t.execute(
            '''CREATE TRIGGER IF NOT EXISTS sr_dup_meta_${table}_${operation.toLowerCase()}_v1
          AFTER $operation ON $table BEGIN
            UPDATE $meta SET revision=revision+1 WHERE id=1;
          END''',
          );
        }
      }
    });
  }

  /// Runs in a worker isolate with at most 128 rows. Return only small digests
  /// and sort keys; long originals never cross back to the UI isolate.
  static List<Map<String, Object?>> _digest(List<Map<String, Object?>> rows) {
    return rows.map((r) {
      final raw = DuplicateProjectionService.normalizeRawContent(
        r['raw_content'],
      );
      final priority = DuplicateProjectionService._priorityTuple(r);
      String text(Object? value) => DuplicateProjectionService._text(value);
      return <String, Object?>{
        'ID': r['ID'],
        'ordinal': r['ordinal'],
        'payload_hash': raw.isEmpty
            ? ''
            : DuplicateProjectionService._payloadHash(raw),
        'legacy_hash': raw.isEmpty
            ? ''
            : DuplicateProjectionService._legacyPayloadHash(raw),
        'field_key': DuplicateProjectionService._payloadHash(
          DuplicateProjectionService._fieldFingerprint(r),
        ),
        'car': text(r['차량번호']),
        'category': text(r['category']),
        'entry_value': text(r['entry_value']),
        'report_number': text(r['신고번호']),
        'fine_rank': priority[0],
        'status_rank': priority[1],
        'answer_rank': priority[2],
        'synced_rank': priority[3],
      };
    }).toList();
  }

  static Future<void> _prepare(Database db) async {
    var cursor = 0;
    while (true) {
      final last = await db.transaction<int?>((t) async {
        final rows = await PerformanceTrace.sql(
          'duplicate.sql_page',
          () => t.rawQuery(
            '''
          SELECT r.rowid AS ordinal, r.ID, r.category, r.entry_value,
            r.차량번호, r.신고내용, r.발생일자, r.발생시각, r.위반장소,
            r.범칙금_과태료, r.처리상태, r.답변일, r.synced_at, r.신고번호,
            rr.raw_content
          FROM reports r LEFT JOIN report_raw rr ON rr.ID=r.ID
          WHERE r.rowid>? AND NOT EXISTS(SELECT 1 FROM $input c WHERE c.ID=r.ID)
          ORDER BY r.rowid LIMIT $pageSize
        ''',
            [cursor],
          ),
        );
        if (rows.isEmpty) return null;
        final timer = Stopwatch()..start();
        final digests = await compute(
          _digest,
          rows,
          debugLabel: 'duplicate.digest',
        );
        PerformanceTrace.record('duplicate.digest', timer, rows: rows.length);
        final batch = t.batch();
        for (final row in digests) {
          batch.insert(
            input,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        return rows.last['ordinal'] as int;
      });
      if (last == null) break;
      cursor = last;
      await Future<void>.delayed(Duration.zero);
    }
  }

  static Future<Map<String, dynamic>> _rebuild(
    Database db,
    bool trackChanges,
  ) async {
    final timer = Stopwatch()..start();
    await _schema(db);
    // Concurrent edits behind the keyset cursor invalidate their digest. Retry
    // preparation rather than committing a mixture of old and new revisions.
    for (var attempt = 0; attempt < 3; attempt++) {
      await _prepare(db);
      // Build once after the initial bulk fill. Maintaining a random digest
      // index for every 128-row transaction amplifies writes on unique raws.
      await db.execute(
        'CREATE INDEX IF NOT EXISTS sr_duplicate_hash_v1 ON $input(payload_hash)',
      );
      // Stage on an independent connection without holding the main write
      // lock. Publish using the shared connection's queue in one short atomic
      // transaction: sqflite's "exclusive:false" still uses BEGIN IMMEDIATE.
      final publisher = await openDatabase(db.path, singleInstance: false);
      Map<String, dynamic>? result;
      try {
        final revision = Sqflite.firstIntValue(
          await publisher.rawQuery('SELECT revision FROM $meta WHERE id=1'),
        )!;
        final missing = Sqflite.firstIntValue(
          await publisher.rawQuery(
            'SELECT COUNT(*) FROM reports r WHERE NOT EXISTS(SELECT 1 FROM $input c WHERE c.ID=r.ID)',
          ),
        )!;
        if (missing == 0) {
          result = await _publish(publisher, db, trackChanges, revision);
        }
      } finally {
        await publisher.close(); // closes/drops connection-local TEMP staging
      }
      if (result != null) {
        PerformanceTrace.record(
          'duplicate.rebuild',
          timer,
          rows: result['member_count'] as int,
        );
        return result;
      }
    }
    throw StateError('동시 변경으로 중복군 계산을 다시 시도해야 합니다. 기존 중복군은 보존했습니다.');
  }

  // Preserve the old Dart List.sort tie behavior exactly, including groups
  // with many equally frequent field fingerprints. Only compact digests enter
  // this worker, with one acknowledged page in flight and one group's keys.
  static void _majorityWorker(SendPort reply) {
    final inputPort = ReceivePort();
    reply.send(inputPort.sendPort);
    var group = '';
    var entries = <MapEntry<String, int>>[];
    List<Object?>? finish() {
      if (group.isEmpty) return null;
      entries.sort((a, b) => b.value.compareTo(a.value));
      return [group, entries.first.key];
    }

    inputPort.listen((message) {
      final winners = <List<Object?>>[];
      if (message == null) {
        final winner = finish();
        if (winner != null) winners.add(winner);
        reply.send(winners);
        inputPort.close();
        return;
      }
      for (final row in message as List) {
        final next = row[0] as String;
        if (group != next) {
          final winner = finish();
          if (winner != null) winners.add(winner);
          group = next;
          entries = <MapEntry<String, int>>[];
        }
        entries.add(MapEntry(row[1] as String, row[2] as int));
      }
      reply.send(winners);
    });
  }

  static Future<void> _legacyMajorities(Database t) async {
    final replies = ReceivePort();
    final worker = await Isolate.spawn(
      _majorityWorker,
      replies.sendPort,
      onError: replies.sendPort,
      onExit: replies.sendPort,
    );
    final iterator = StreamIterator<dynamic>(replies);
    try {
      await iterator.moveNext();
      final sender = iterator.current as SendPort;
      Future<void> accept() async {
        if (!await iterator.moveNext()) {
          throw StateError('중복 비교 worker가 종료되었습니다.');
        }
        final batch = t.batch();
        for (final winner in iterator.current as List) {
          batch.update(
            'sr_dup_groups',
            {'majority': winner[1]},
            where: 'payload_hash=?',
            whereArgs: [winner[0]],
          );
        }
        await batch.apply(noResult: true);
      }

      var cursor = 0;
      // CTAS rowid preserves first-seen field order per group without OFFSET.
      await t.execute(
        'CREATE TEMP TABLE sr_dup_field_order AS SELECT * FROM sr_dup_fields ORDER BY payload_hash,first_ordinal',
      );
      try {
        while (true) {
          final rows = await PerformanceTrace.sql(
            'duplicate.field_page',
            () => t.rawQuery(
              'SELECT rowid AS cursor,payload_hash,field_key,frequency FROM sr_dup_field_order WHERE rowid>? ORDER BY rowid LIMIT 128',
              [cursor],
            ),
          );
          if (rows.isEmpty) break;
          cursor = rows.last['cursor'] as int;
          sender.send(
            rows
                .map((r) => [r['payload_hash'], r['field_key'], r['frequency']])
                .toList(),
          );
          await accept();
        }
        sender.send(null);
        await accept();
      } finally {
        await t.execute('DROP TABLE IF EXISTS temp.sr_dup_field_order');
      }
    } finally {
      await iterator.cancel();
      replies.close();
      worker.kill(priority: Isolate.immediate);
    }
  }

  static Future<Map<String, dynamic>?> _publish(
    Database t,
    Database shared,
    bool trackChanges,
    int expectedRevision,
  ) async {
    final now = DuplicateProjectionService._nowMs();
    // SQLite does the full grouping/sorting. No window functions (Android 23
    // SQLite compatibility): CTAS rowids give contiguous positions per group.
    await t.execute('''CREATE TEMP TABLE sr_dup_rank AS SELECT c.* FROM $input c
      WHERE payload_hash<>'' AND payload_hash IN
        (SELECT payload_hash FROM $input WHERE payload_hash<>'' GROUP BY payload_hash HAVING COUNT(*)>1)
      ORDER BY payload_hash, fine_rank DESC, status_rank DESC, answer_rank DESC,
        synced_rank DESC, report_number DESC, ordinal''');
    await t.execute(
      'CREATE INDEX sr_dup_rank_hash ON sr_dup_rank(payload_hash)',
    );
    await t.execute('''CREATE TEMP TABLE sr_dup_fields AS
      SELECT payload_hash,field_key,COUNT(*) AS frequency,MIN(ordinal) AS first_ordinal
      FROM sr_dup_rank GROUP BY payload_hash,field_key''');
    await t.execute(
      'CREATE INDEX sr_dup_fields_priority ON sr_dup_fields(payload_hash,frequency DESC,first_ordinal)',
    );
    await t.execute('''CREATE TEMP TABLE sr_dup_groups AS
      SELECT payload_hash,COUNT(*) AS member_count,MIN(rowid) AS first_rank,
        (COUNT(DISTINCT NULLIF(car,''))>1 OR COUNT(DISTINCT NULLIF(category,''))>1
          OR COUNT(DISTINCT NULLIF(entry_value,''))>1) AS conflict,
        (SELECT f.field_key FROM sr_dup_fields f WHERE f.payload_hash=c.payload_hash
          ORDER BY frequency DESC,first_ordinal LIMIT 1) AS majority
      FROM sr_dup_rank c GROUP BY payload_hash''');
    await t.execute(
      'CREATE UNIQUE INDEX sr_dup_groups_hash ON sr_dup_groups(payload_hash)',
    );
    await _legacyMajorities(t);
    await t.execute(
      'CREATE TEMP TABLE sr_dup_new_groups AS SELECT * FROM duplicate_group WHERE 0',
    );
    await t.execute(
      'CREATE UNIQUE INDEX sr_dup_new_groups_id ON sr_dup_new_groups(group_id)',
    );
    var cursor = '';
    final alerts = <Map<String, dynamic>>[];
    while (true) {
      final rows = await PerformanceTrace.sql(
        'duplicate.group_page',
        () => t.rawQuery(
          '''
        SELECT s.*, c.ID AS recommended, c.legacy_hash,
          COALESCE(g.group_id,d.group_id,l.group_id) AS existing_id,
          CASE WHEN d.group_id IS NOT NULL THEN d.status ELSE COALESCE(g.status,l.status) END AS old_status,
          CASE WHEN d.group_id IS NOT NULL THEN d.representative_mode ELSE COALESCE(g.representative_mode,l.representative_mode) END AS old_mode,
          CASE WHEN d.group_id IS NOT NULL THEN d.representative_id ELSE COALESCE(g.representative_id,l.representative_id) END AS old_rep,
          CASE WHEN d.group_id IS NOT NULL THEN d.note ELSE COALESCE(g.note,l.note) END AS old_note,
          COALESCE(g.created_at,l.created_at) AS old_created,
          EXISTS(SELECT 1 FROM $input i WHERE i.ID=CASE WHEN d.group_id IS NOT NULL THEN d.representative_id
            ELSE COALESCE(g.representative_id,l.representative_id) END AND i.payload_hash=s.payload_hash) AS manual_valid,
          (SELECT COUNT(*) FROM duplicate_member m WHERE m.group_id=s.payload_hash) AS old_count,
          EXISTS(SELECT 1 FROM duplicate_member m WHERE m.group_id=s.payload_hash
            AND NOT EXISTS(SELECT 1 FROM $input i WHERE i.ID=m.report_id AND i.payload_hash=s.payload_hash)) AS old_missing
        FROM sr_dup_groups s JOIN sr_dup_rank c ON c.rowid=s.first_rank
        LEFT JOIN duplicate_group g ON g.group_id=s.payload_hash
        LEFT JOIN duplicate_decision d ON d.group_id=s.payload_hash
        LEFT JOIN duplicate_group l ON g.group_id IS NULL AND d.group_id IS NULL
          AND l.rowid=(SELECT rowid FROM duplicate_group WHERE fingerprint=c.legacy_hash ORDER BY rowid DESC LIMIT 1)
        WHERE s.payload_hash>? ORDER BY s.payload_hash LIMIT $pageSize
      ''',
          [cursor],
        ),
      );
      if (rows.isEmpty) break;
      final batch = t.batch();
      for (final r in rows) {
        final id = r['payload_hash'] as String;
        final existing = r['existing_id'] != null;
        final oldStatus = DuplicateProjectionService.normalizeDuplicateStatus(
          r['old_status'],
        );
        final mode = existing
            ? DuplicateProjectionService.normalizeRepresentativeMode(
                r['old_mode'],
                existingStatus: r['old_status'],
              )
            : 'auto';
        final status = oldStatus.isNotEmpty
            ? oldStatus
            : r['conflict'] == 1
            ? 'review_required'
            : 'confirmed_duplicate';
        final rep = mode == 'manual' && r['manual_valid'] == 1
            ? r['old_rep']
            : r['recommended'];
        batch.insert('sr_dup_new_groups', {
          'group_id': id,
          'fingerprint': id,
          'match_type': 'payload_exact',
          'status': status,
          'representative_mode': mode,
          'representative_id': rep,
          'member_count': r['member_count'],
          'apply_globally': status == 'confirmed_duplicate' ? 1 : 0,
          'note': r['old_note']?.toString() ?? '',
          'created_at': int.tryParse('${r['old_created']}') ?? now,
          'updated_at': now,
        });
        if (trackChanges) {
          final kind = !existing
              ? 'group_added'
              : r['old_count'] != r['member_count'] || r['old_missing'] == 1
              ? 'members_changed'
              : mode == 'auto' && r['old_rep'] != rep
              ? 'representative_changed'
              : '';
          if (kind.isNotEmpty) {
            final representative = (await t.rawQuery(
              '''SELECT r.ID AS report_id,r.신고번호,r.신고명,
              r.처리상태,r.처리기관,r.범칙금_과태료 FROM reports r WHERE ID=?''',
              [rep],
            )).first;
            // Notifications need the representative and the true population,
            // not copies of every member's raw payload in preferences.
            alerts.add(
              DuplicateProjectionService._buildDuplicateAlertPayload(
                changeKind: kind,
                groupId: id,
                status: status,
                representativeMode: mode,
                memberCount: r['member_count'] as int,
                representative: representative,
                members: const [],
              )..['members_deferred'] = true,
            );
          }
        }
      }
      await batch.apply(noResult: true);
      cursor = rows.last['payload_hash'] as String;
      await Future<void>.delayed(Duration.zero);
    }
    await t.execute(
      '''CREATE TEMP TABLE sr_dup_new_members AS
      SELECT g.group_id,c.ID AS report_id,c.report_number,c.category,
        (c.ID=g.representative_id) AS is_representative,
        g.member_count-(c.rowid-s.first_rank) AS priority_score,
        1 AS raw_match,(c.field_key=s.majority) AS field_match,
        COALESCE(m.created_at,?) AS created_at,? AS updated_at
      FROM sr_dup_rank c JOIN sr_dup_new_groups g ON g.group_id=c.payload_hash
      JOIN sr_dup_groups s ON s.payload_hash=c.payload_hash
      LEFT JOIN duplicate_member m ON m.group_id=g.group_id AND m.report_id=c.ID''',
      [now, now],
    );
    final count = Sqflite.firstIntValue(
      await t.rawQuery('SELECT COUNT(*) FROM sr_dup_new_members'),
    )!;
    final groupCount = Sqflite.firstIntValue(
      await t.rawQuery('SELECT COUNT(*) FROM sr_dup_new_groups'),
    )!;
    final staging = await Directory.systemTemp.createTemp(
      'sr_duplicate_stage_',
    );
    final path = '${staging.path}/projection.db';
    var attached = false;
    try {
      await t.execute('ATTACH DATABASE ? AS sr_dup_output', [path]);
      await t.execute(
        'CREATE TABLE sr_dup_output.groups AS SELECT * FROM temp.sr_dup_new_groups',
      );
      await t.execute(
        'CREATE TABLE sr_dup_output.members AS SELECT * FROM temp.sr_dup_new_members',
      );
      await t.execute('DETACH DATABASE sr_dup_output');
      await shared.execute('ATTACH DATABASE ? AS sr_dup_output', [path]);
      attached = true;
      final committed = await shared.transaction((txn) async {
        final revision = Sqflite.firstIntValue(
          await txn.rawQuery('SELECT revision FROM $meta WHERE id=1'),
        )!;
        if (revision != expectedRevision) return false;
        await txn.delete('duplicate_member');
        await txn.delete('duplicate_group');
        await txn.execute(
          'INSERT INTO duplicate_group SELECT * FROM sr_dup_output.groups',
        );
        await txn.execute(
          'INSERT INTO duplicate_member SELECT * FROM sr_dup_output.members',
        );
        await txn.execute(
          'UPDATE $meta SET built_revision=revision WHERE id=1',
        );
        return true;
      });
      if (!committed) return null;
    } finally {
      if (attached) await shared.execute('DETACH DATABASE sr_dup_output');
      await staging.delete(recursive: true);
    }
    return {
      'group_count': groupCount,
      'member_count': count,
      'changes': alerts,
    };
  }
}
