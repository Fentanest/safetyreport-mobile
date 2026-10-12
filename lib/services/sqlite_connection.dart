import 'package:sqflite/sqflite.dart';

/// Applies connection-local settings on every open, including independent
/// WorkManager engines, snapshot readers and duplicate rebuild publishers.
/// Keep journal mode at the call site: portable exports intentionally use DELETE.
const sqliteBusyTimeoutMs = 5000;

Future<Database> openAppDatabase(
  String path, {
  DatabaseFactory? factory,
  int? version,
  OnDatabaseConfigureFn? onConfigure,
  OnDatabaseCreateFn? onCreate,
  OnDatabaseVersionChangeFn? onUpgrade,
  bool readOnly = false,
  bool singleInstance = true,
  int busyTimeoutMs = sqliteBusyTimeoutMs,
}) => (factory ?? databaseFactory).openDatabase(
  path,
  options: OpenDatabaseOptions(
    version: version,
    readOnly: readOnly,
    singleInstance: singleInstance,
    onConfigure: (db) async {
      // Set this before WAL/schema work, which can itself need a lock. This
      // also runs for readOnly opens with our pinned sqflite_common version.
      await db.rawQuery('PRAGMA busy_timeout=$busyTimeoutMs');
      await onConfigure?.call(db);
    },
    onCreate: onCreate,
    onUpgrade: onUpgrade,
  ),
);
