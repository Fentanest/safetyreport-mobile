// v11 cannot migrate v9 ciphertext. Check the v10 marker before opening storage;
// never reinterpret a read failure as an empty account or erase it to proceed.
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs_keys.dart';

enum SecureStorageReadiness { ready, reauthenticationRequired, unavailable }

class SecureStorageMigration {
  SecureStorageMigration._();

  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false));
  static const _channel = MethodChannel(
    'com.fentanest.mysafetyreport/secure_storage',
  );

  static Future<bool> isDone([SharedPreferences? prefs]) async {
    try {
      final p = prefs ?? await SharedPreferences.getInstance();
      if (prefs == null) await p.reload();
      return p.getBool(AppPrefsKeys.secureStorageV10Migrated) == true ||
          p.getBool(AppPrefsKeys.secureStorageV11Initialized) == true;
    } catch (_) {
      return false;
    }
  }

  /// Fresh installs get a separate v11 marker, never a fabricated v10 migration.
  /// Android inspection reads only key names, before the plugin can touch v9 data.
  static Future<SecureStorageReadiness> checkReady({
    @visibleForTesting FlutterSecureStorage? storage,
    @visibleForTesting Future<int> Function()? storedEntries,
    @visibleForTesting bool? isAndroid,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ready = await isDone(prefs);
      if (!ready &&
          (isAndroid ??
              (!kIsWeb && defaultTargetPlatform == TargetPlatform.android))) {
        final count = await (storedEntries ?? _storedEntries)();
        if (count < 0) return SecureStorageReadiness.unavailable;
        if (count > 0 || prefs.getKeys().isNotEmpty) {
          return SecureStorageReadiness.reauthenticationRequired;
        }
      }
      // Also check marked installs: a Keystore error is not a logged-out state.
      await (storage ?? _storage).readAll();
      if (!ready) {
        if (!await prefs.setBool(
          AppPrefsKeys.secureStorageV11Initialized,
          true,
        )) {
          return SecureStorageReadiness.unavailable;
        }
      }
      return SecureStorageReadiness.ready;
    } catch (_) {
      return SecureStorageReadiness.unavailable;
    }
  }

  static Future<int> _storedEntries() async =>
      (await _channel.invokeMethod<int>('storedSecureEntries')) ?? -1;
}
