import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One factory per Flutter engine/isolate. Capture the Android plugin's existing
/// directory before replacing its factory: FFI's default directory is different.
/// sqlite3 3.x supplies the native asset to the worker isolate as well.
class BundledSqlite {
  BundledSqlite._();

  static Future<void>? _initializing;

  static Future<void> initialize() {
    if (!Platform.isAndroid) return Future<void>.value();
    return _initializing ??=
        install(
          platformFactory: databaseFactorySqflitePlugin,
          bundledFactory: databaseFactoryFfi,
        ).catchError((Object error, StackTrace stack) {
          _initializing = null;
          Error.throwWithStackTrace(error, stack);
        });
  }

  @visibleForTesting
  static Future<void> install({
    required DatabaseFactory platformFactory,
    required DatabaseFactory bundledFactory,
  }) async {
    final existingPath = await platformFactory.getDatabasesPath();
    sqfliteFfiInit();
    await bundledFactory.setDatabasesPath(existingPath);
    databaseFactory = bundledFactory;
  }
}
