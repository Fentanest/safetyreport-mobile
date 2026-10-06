import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:sqflite/sqflite.dart';

/// External databases are opened read-only. A read transaction keeps main/WAL
/// at one snapshot while bounded pages are copied to a private destination.
/// If [sourceSnapshot] is supplied, the caller must hold its transaction until
/// this finishes. This avoids reopening an exclusively locked Android source.
Future<void> copyReadOnlyDatabaseSnapshot(
  String sourcePath,
  String target, {
  DatabaseExecutor? sourceSnapshot,
}) async {
  if (File(sourcePath).absolute.path == File(target).absolute.path ||
      await File(target).exists()) {
    throw const FormatException('사본 경로는 새 private 파일이어야 합니다.');
  }
  Database? source;
  Database? destination;
  var complete = false;
  String quote(String value) => '"${value.replaceAll('"', '""')}"';
  try {
    if (sourceSnapshot == null) {
      source = await openDatabase(
        sourcePath,
        readOnly: true,
        singleInstance: false,
      );
    }
    destination = await openDatabase(target, singleInstance: false);
    final output = destination;
    Future<void> copyFrom(DatabaseExecutor input) async {
      final objects = await input.rawQuery(
        "SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY rowid",
      );
      await output.transaction((copy) async {
        final tables = objects.where((r) => r['type'] == 'table').toList();
        bool virtual(Map<String, Object?> row) => RegExp(
          r'^\s*CREATE\s+VIRTUAL\s+TABLE',
          caseSensitive: false,
        ).hasMatch(row['sql'] as String);
        for (final row in tables.where(virtual)) {
          await copy.execute(row['sql'] as String);
        }
        for (final row in tables.where((r) => !virtual(r))) {
          final name = row['name'] as String;
          final exists = await copy.rawQuery(
            'SELECT 1 FROM sqlite_master WHERE name=?',
            [name],
          );
          if (exists.isEmpty) {
            await copy.execute(row['sql'] as String);
          } else {
            await copy.delete(name);
          }
          final columns = await input.rawQuery(
            'PRAGMA table_info(${quote(name)})',
          );
          final names = columns.map((r) => r['name'] as String).toSet();
          final withoutRowid = RegExp(
            r'WITHOUT\s+ROWID',
            caseSensitive: false,
          ).hasMatch(row['sql'] as String);
          var cursorAlias = '_sr_snapshot_cursor';
          while (names.contains(cursorAlias)) {
            cursorAlias += '_';
          }
          final aliases = [
            'rowid',
            '_rowid_',
            'oid',
          ].where((a) => !names.contains(a)).toList();
          final cursor = !withoutRowid && aliases.isNotEmpty
              ? aliases.first
              : null;
          final order =
              cursor ??
              columns
                  .where((r) => (r['pk'] as int) > 0)
                  .map((r) => quote(r['name'] as String))
                  .join(',');
          int? last;
          var offset = 0;
          while (true) {
            final projection = cursor == null
                ? '*'
                : '${quote(cursor)} AS ${quote(cursorAlias)},*';
            final rows = await input.rawQuery(
              'SELECT $projection FROM ${quote(name)} ${last == null || cursor == null ? '' : 'WHERE ${quote(cursor)}> ?'} ${order.isEmpty ? '' : 'ORDER BY $order'} LIMIT 128 ${cursor == null ? 'OFFSET $offset' : ''}',
              last == null || cursor == null ? [] : [last],
            );
            if (rows.isEmpty) break;
            final batch = copy.batch();
            for (final raw in rows) {
              final values = Map<String, Object?>.from(raw);
              if (cursor != null) {
                values.remove(cursorAlias);
                values[cursor] = raw[cursorAlias];
              }
              batch.insert(
                name,
                values,
                conflictAlgorithm: ConflictAlgorithm.abort,
              );
            }
            await batch.commit(noResult: true);
            final actual = await copy.rawQuery(
              'SELECT $projection FROM ${quote(name)} ${last == null || cursor == null ? '' : 'WHERE ${quote(cursor)}> ?'} ${order.isEmpty ? '' : 'ORDER BY $order'} LIMIT 128 ${cursor == null ? 'OFFSET $offset' : ''}',
              last == null || cursor == null ? [] : [last],
            );
            if (actual.length != rows.length) {
              throw FormatException('$name 사본 행 수 불일치');
            }
            for (var i = 0; i < rows.length; i++) {
              for (final entry in rows[i].entries) {
                final value = actual[i][entry.key];
                final expected = entry.value;
                final equal = expected is List<int> && value is List<int>
                    ? listEquals(expected, value)
                    : value == expected;
                final type = expected == null
                    ? value == null
                    : expected is List<int>
                    ? value is List<int>
                    : expected.runtimeType == value.runtimeType;
                if (!equal || !type) {
                  throw FormatException('$name.${entry.key} 사본 값/타입 불일치');
                }
              }
            }
            offset += rows.length;
            if (cursor != null) last = rows.last[cursorAlias] as int;
          }
        }
        final sequences = await input.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE name='sqlite_sequence'",
        );
        if (sequences.isNotEmpty) {
          await copy.delete('sqlite_sequence');
          for (final row in await input.query('sqlite_sequence')) {
            await copy.insert('sqlite_sequence', row);
          }
        }
        for (final type in ['index', 'view', 'trigger']) {
          for (final row in objects.where((r) => r['type'] == type)) {
            if ((await copy.rawQuery(
              'SELECT 1 FROM sqlite_master WHERE name=?',
              [row['name']],
            )).isEmpty) {
              await copy.execute(row['sql'] as String);
            }
          }
        }
        final version =
            Sqflite.firstIntValue(
              await input.rawQuery('PRAGMA user_version'),
            ) ??
            0;
        await copy.execute('PRAGMA user_version=$version');
      });
    }

    if (sourceSnapshot != null) {
      await copyFrom(sourceSnapshot);
    } else {
      await source!.transaction(copyFrom, exclusive: false);
    }
    if ((await output.rawQuery('PRAGMA integrity_check')).first.values.first !=
        'ok') {
      throw const FormatException('사본 무결성 검사 실패');
    }
    complete = true;
  } finally {
    await destination?.close();
    await source?.close();
    if (!complete) {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final file = File('$target$suffix');
        if (await file.exists()) await file.delete();
      }
    }
  }
}
