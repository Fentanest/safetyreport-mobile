// SQ-B14: 설정의 Standalone 재로그인 창이 닫히면 아이디·비밀번호·전화번호 컨트롤러를 해제하고,
// 비밀번호는 지운 뒤 해제한다(평문이 메모리에 남지 않게).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _StandaloneProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;

  @override
  String get standaloneUsername => 'user';

  @override
  Future<void> refreshAll() async {}
}

bool _isDisposed(ChangeNotifier notifier) {
  try {
    notifier.addListener(() {});
    return false;
  } on FlutterError {
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  const perm = MethodChannel('com.fentanest.mysafetyreport/permissions');

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_relogin_dispose_');
    await databaseFactory.setDatabasesPath(dir.path);
    PackageInfo.setMockInitialValues(
      appName: 'safetyreport',
      packageName: 'x',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  testWidgets('closing the re-login dialog clears the password and disposes '
      'its controllers', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(perm, (_) async => false);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(perm, null),
    );
    final provider = _StandaloneProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: SettingsScreen(openReloginOnStart: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('안전신문고 재로그인'), findsOneWidget);

    TextEditingController controllerOf(String label) => tester
        .widget<TextField>(find.widgetWithText(TextField, label))
        .controller!;
    final username = controllerOf('아이디');
    final password = controllerOf('비밀번호');
    final phone = controllerOf('휴대폰번호');
    await tester.enterText(find.widgetWithText(TextField, '비밀번호'), 'secret');
    expect(password.text, 'secret');

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(find.text('안전신문고 재로그인'), findsNothing);
    expect(password.text, isEmpty, reason: '비밀번호는 지운 뒤 해제한다');
    expect(_isDisposed(username), isTrue);
    expect(_isDisposed(password), isTrue);
    expect(_isDisposed(phone), isTrue);
  });
}
