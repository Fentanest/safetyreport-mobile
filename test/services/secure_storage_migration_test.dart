// 보안 저장소 v10 이관 확정 표시(포그라운드만 이관, 확인 전에는 평소 화면·백그라운드가 보안 저장소를 쓰지 않는다).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/screens/secure_storage_recovery_screen.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/background_login_check.dart';
import 'package:safetyreport/services/secure_storage_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Throwing extends FlutterSecureStorage {
  const _Throwing();
  @override
  Future<String?> read({required String key, AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions,
          WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async =>
      throw Exception('keystore');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'community_session_v1': 's', 'community_connection_v1': 'c'});
  });

  test('the foreground opens both storages once and records the marker', () async {
    expect(await SecureStorageMigration.isDone(), isFalse);
    expect(await SecureStorageMigration.ensureMigrated(isAndroid: true, unmigratedEntries: () async => 0), isTrue);
    expect(await SecureStorageMigration.isDone(), isTrue);
  });

  test('reads that silently fell back (v9 ESP entries still on disk) leave no marker', () async {
    expect(await SecureStorageMigration.ensureMigrated(isAndroid: true, unmigratedEntries: () async => 3), isFalse);
    expect(await SecureStorageMigration.isDone(), isFalse);
    expect(await SecureStorageMigration.ensureMigrated(isAndroid: true, unmigratedEntries: () async => -1), isFalse,
        reason: '확인 못 함은 완료가 아니다');
    expect(await SecureStorageMigration.isDone(), isFalse);
  });

  test('iOS keychain items need no migration (same service and accessibility)', () async {
    expect(await SecureStorageMigration.ensureMigrated(isAndroid: false), isTrue);
    expect(await SecureStorageMigration.isDone(), isTrue);
  });

  test('a failed open leaves no marker (retried next start) and writes nothing', () async {
    expect(await SecureStorageMigration.ensureMigrated(esp: const _Throwing(), isAndroid: true, unmigratedEntries: () async => 0),
        isFalse);
    expect(await SecureStorageMigration.isDone(), isFalse);
  });

  testWidgets('the recovery screen only offers a restart (no way around the Kakao login)', (tester) async {
    var exits = 0;
    await tester.pumpWidget(SecureStorageRecoveryApp(exit: () async => exits++));
    await tester.pumpAndSettle();
    expect(find.text('저장된 로그인 정보를 준비하지 못했습니다'), findsOneWidget);
    expect(find.textContaining('지우고 계속'), findsNothing);
    await tester.tap(find.text('앱 종료(다시 열어 재시도)'));
    expect(exits, 1);
  });

  test('background tasks do not open secure storage before the marker', () async {
    SharedPreferences.setMockInitialValues({AppPrefsKeys.appMode: AppMode.standalone.name});
    var opened = false;
    expect(
        await runCommunityUploadTask('community-upload-periodic', openStore: () async {
          opened = true;
          return null;
        }),
        isTrue);
    expect(opened, isFalse, reason: '표시 전에는 저장소·보안 저장소를 열지 않고 다음 기회로');
    expect(await BackgroundLoginCheck.run(), isFalse);
  });
}
