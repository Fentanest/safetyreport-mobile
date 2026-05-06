import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/pending_db_import_action.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PendingDbImportAction.decode', () {
    test('decodes supported action formats', () {
      expect(
        PendingDbImportAction.decode('convert:/tmp/server.db'),
        isA<ConvertServerDbAction>(),
      );
      expect(
        PendingDbImportAction.decode('copy:/tmp/mobile.db'),
        isA<CopyMobileBackupAction>(),
      );
      expect(
        PendingDbImportAction.decode('file:/tmp/selected.db'),
        isA<DetectAndApplyDbFileAction>(),
      );
      expect(PendingDbImportAction.decode('unknown:/tmp/x.db'), isNull);
      expect(PendingDbImportAction.decode(null), isNull);
    });
  });

  group('PendingDbImportAction persistence', () {
    test('save and readAndClear round-trips encoded action', () async {
      await PendingDbImportAction.save(
        const DetectAndApplyDbFileAction('/tmp/picked.db'),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AppPrefsKeys.pendingDbImport),
        'file:/tmp/picked.db',
      );

      final action = await PendingDbImportAction.readAndClear();
      expect(action, isA<DetectAndApplyDbFileAction>());
      expect(action?.encode(), 'file:/tmp/picked.db');
      expect(prefs.getString(AppPrefsKeys.pendingDbImport), isNull);
    });

    test('save null clears any pending action', () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.pendingDbImport: 'copy:/tmp/backup.db',
      });

      await PendingDbImportAction.save(null);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppPrefsKeys.pendingDbImport), isNull);
    });
  });
}
