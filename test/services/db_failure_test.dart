// 2026-10-17 제보 대응: 다시 불러오기 판정 실패를 저장공간 부족·DB 잠금·그 밖으로 나눈다. 번들 SQLite(FFI)의 실제 예외로 확인한다.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/db_failure.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfiNoIsolate;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('db_failure_test_');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('SQLITE_FULL (page limit) is storageFull', () async {
    final db = await factory.openDatabase('${dir.path}/full.db');
    await db.execute('CREATE TABLE t (v BLOB)');
    final pages = (await db.rawQuery('PRAGMA page_count')).first.values.first;
    await db.rawQuery('PRAGMA max_page_count = $pages');
    Object? error;
    try {
      await db.insert('t', {'v': Uint8List(64 * 1024)});
    } catch (e) {
      error = e;
    }
    await db.close();
    expect(error, isNotNull);
    expect(classifyDbFailure(error), DbFailureKind.storageFull);
  });

  test('SQLITE_BUSY from another writer is locked', () async {
    final path = '${dir.path}/busy.db';
    final holder = await factory.openDatabase(path);
    await holder.execute('CREATE TABLE t (v INTEGER)');
    final other = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await other.rawQuery('PRAGMA busy_timeout = 0');
    await holder.execute('BEGIN EXCLUSIVE');
    Object? error;
    try {
      await other.insert('t', {'v': 1});
    } catch (e) {
      error = e;
    }
    await holder.execute('ROLLBACK');
    await other.close();
    await holder.close();
    expect(error, isNotNull);
    expect(classifyDbFailure(error), DbFailureKind.locked);
  });

  test('ENOSPC file error and message fallbacks', () {
    expect(
      classifyDbFailure(
        const FileSystemException('write', '/x', OSError('No space', 28)),
      ),
      DbFailureKind.storageFull,
    );
    expect(
      classifyDbFailure(Exception('database or disk is full')),
      DbFailureKind.storageFull,
    );
    expect(
      classifyDbFailure(Exception('database is locked')),
      DbFailureKind.locked,
    );
    expect(classifyDbFailure(StateError('scope')), DbFailureKind.other);
    expect(classifyDbFailure(null), DbFailureKind.other);
  });

  test('describe hides the app data path and truncates', () {
    final text = describeDbFailure(
      Exception(
        'open /data/user/0/com.fentanest.mysafetyreport/databases/a.db',
      ),
    );
    expect(text, contains('<app>/databases/a.db'));
    expect(text, isNot(contains('com.fentanest')));
    expect(describeDbFailure(Exception('x' * 1000), maxLength: 50).length, 51);
  });
}
