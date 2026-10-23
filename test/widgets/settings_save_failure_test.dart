import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/settings_screen.dart';
import 'package:safetyreport/services/client_compatibility.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealSockets extends HttpOverrides {}

class _OfflineProvider extends ReportProvider {
  _OfflineProvider(this.url);
  final String url;
  int refreshes = 0;
  @override
  String get baseUrl => url;
  @override
  String get apiKey => 'unused-local-connection';
  @override
  Future<void> refreshAll() async => refreshes++;
}

void main() {
  testWidgets('실제 연결 거부 후 설정값을 유지하고 다시 시도할 수 있다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ClientCompatibility.invalidate();
    PackageInfo.setMockInitialValues(
      appName: 'safetyreport',
      packageName: 'safetyreport',
      version: '2.5.1',
      buildNumber: '180',
      buildSignature: '',
    );
    const channel = MethodChannel('com.fentanest.mysafetyreport/permissions');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    late int port;
    await tester.runAsync(() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = socket.port;
      await socket.close();
    });
    final provider = _OfflineProvider('http://127.0.0.1:$port');
    addTearDown(provider.dispose);
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // HTTP 응답을 만들어 주지 않는다. 닫힌 loopback 포트의 실제 연결 거부를 쓴다.
    await HttpOverrides.runWithHttpOverrides(() async {
      await http.runWithClient(() async {
        await tester.pumpWidget(
          ChangeNotifierProvider<ReportProvider>.value(
            value: provider,
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        for (final label in [
          '취하 데이터 숨기기',
          '중복 신고 대표건만 반영',
          '엑셀 자동 저장',
          '구글 스프레드시트 자동 업로드',
        ]) {
          final toggle = find.widgetWithText(SwitchListTile, label);
          final before = tester.widget<SwitchListTile>(toggle).value;
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pump();
          expect(tester.widget<SwitchListTile>(toggle).value, before);
          for (var i = 0; i < 100; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
            if (tester.widget<SwitchListTile>(toggle).onChanged != null) break;
          }
          expect(tester.widget<SwitchListTile>(toggle).value, before);
          expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
          expect(find.textContaining('설정을 저장하지 못했습니다'), findsWidgets);
          expect(provider.refreshes, 0);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => IOClient(HttpClient()));
    }, _RealSockets());
    ClientCompatibility.invalidate();
  });
}
