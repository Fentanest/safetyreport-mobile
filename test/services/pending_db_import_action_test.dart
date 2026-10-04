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
    test(
      'save and read round-trip the encoded action without clearing it',
      () async {
        await PendingDbImportAction.save(
          const DetectAndApplyDbFileAction('/tmp/picked.db'),
        );

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(AppPrefsKeys.pendingDbImport),
          'file:/tmp/picked.db',
        );

        final action = await PendingDbImportAction.read();
        expect(action, isA<DetectAndApplyDbFileAction>());
        expect(action?.encode(), 'file:/tmp/picked.db');
        expect(action?.path, '/tmp/picked.db');
        // 읽기만으로는 지우지 않는다(SQ-B03 — 예전 readAndClear 는 적용 전에 지웠다).
        expect(
          prefs.getString(AppPrefsKeys.pendingDbImport),
          'file:/tmp/picked.db',
        );
      },
    );

    test('save null clears any pending action', () async {
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.pendingDbImport: 'copy:/tmp/backup.db',
      });

      await PendingDbImportAction.save(null);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppPrefsKeys.pendingDbImport), isNull);
    });
  });

  // SQ-B03: 적용에 성공하거나 사용자가 버릴 때만 지운다. 실패하면 남겨 다시 시도할 수 있다.
  group('PendingDbImportAction.applyPending', () {
    late int attempts;
    late int failUntil;

    setUp(() {
      attempts = 0;
      failUntil = 0;
      SharedPreferences.setMockInitialValues({
        AppPrefsKeys.pendingDbImport: 'convert:/tmp/server_db_1.db',
      });
      PendingDbImportAction.applyOverride = (action) async {
        attempts++;
        if (attempts <= failUntil) throw Exception('disk full');
        return 'ok ${action.path}';
      };
    });
    tearDown(() => PendingDbImportAction.applyOverride = null);

    Future<String?> stored() async => (await SharedPreferences.getInstance())
        .getString(AppPrefsKeys.pendingDbImport);

    test('no pending action does nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final outcome = await PendingDbImportAction.applyPending(
        onFailure: (_, _) async => fail('no failure expected'),
      );
      expect(outcome.status, PendingDbImportStatus.none);
      expect(attempts, 0);
    });

    test('success removes the action', () async {
      final outcome = await PendingDbImportAction.applyPending(
        onFailure: (_, _) async => fail('no failure expected'),
      );
      expect(outcome.status, PendingDbImportStatus.applied);
      expect(outcome.message, 'ok /tmp/server_db_1.db');
      expect(await stored(), isNull);
    });

    test('failure keeps the action while asking, and retry succeeds', () async {
      failUntil = 1;
      final asked = <String?>[];
      final outcome = await PendingDbImportAction.applyPending(
        onFailure: (action, error) async {
          asked.add(await stored());
          expect(action.path, '/tmp/server_db_1.db');
          expect('$error', contains('disk full'));
          return PendingDbImportFailureChoice.retry;
        },
      );
      expect(asked, ['convert:/tmp/server_db_1.db']);
      expect(attempts, 2);
      expect(outcome.status, PendingDbImportStatus.applied);
      expect(await stored(), isNull);
    });

    test('discard removes the action', () async {
      failUntil = 99;
      final outcome = await PendingDbImportAction.applyPending(
        onFailure: (_, _) async => PendingDbImportFailureChoice.discard,
      );
      expect(outcome.status, PendingDbImportStatus.discarded);
      expect(outcome.action?.path, '/tmp/server_db_1.db');
      expect(await stored(), isNull);
    });

    test('no decision keeps the action for the next login', () async {
      failUntil = 99;
      final outcome = await PendingDbImportAction.applyPending(
        onFailure: (_, _) async => null,
      );
      expect(outcome.status, PendingDbImportStatus.kept);
      expect(await stored(), 'convert:/tmp/server_db_1.db');
    });

    test('does not remove a newer action saved meanwhile', () async {
      PendingDbImportAction.applyOverride = (action) async {
        await PendingDbImportAction.save(
          const CopyMobileBackupAction('/tmp/newer.db'),
        );
        return null;
      };
      await PendingDbImportAction.applyPending(onFailure: (_, _) async => null);
      expect(await stored(), 'copy:/tmp/newer.db');
    });
  });
}
