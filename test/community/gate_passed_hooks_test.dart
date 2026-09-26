// F18: 게이트 전 BackgroundLoginCheck.schedule·drain 미호출, 통과 뒤 1회 호출.
//
// 위젯 테스트와 같은 프로세스에서 돌리면 LocalDbService 정적 캐시(_initFuture)가
// FakeAsync zone 에서 만들어져 영원히 대기하므로 별도 파일로 분리한다.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/standalone_auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ReportProvider> _providerWith(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final provider = ReportProvider();
  await provider.init();
  return provider;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    ReportProvider.scheduleLoginCheckHook = null;
    ReportProvider.drainAndRefreshHook = null;
    ReportProvider.startWsServiceHook = null;
    StandaloneAuthService.stopKeepAlive();
  });

  test('F18: init calls no schedule/drain; onGatePassed calls them once',
      () async {
    var scheduleCalls = 0;
    var drainCalls = 0;
    var wsCalls = 0;
    ReportProvider.scheduleLoginCheckHook = () async {
      scheduleCalls++;
    };
    ReportProvider.drainAndRefreshHook = () async {
      drainCalls++;
    };
    ReportProvider.startWsServiceHook = () async {
      wsCalls++;
      return true;
    };
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'standalone',
      AppPrefsKeys.standaloneUsername: 'user1',
    });
    expect(scheduleCalls, 0);
    expect(drainCalls, 0);
    expect(wsCalls, 0);
    await provider.onGatePassed();
    expect(scheduleCalls, 1);
    expect(drainCalls, 1);
    await provider.onGatePassed();
    expect(scheduleCalls, 1, reason: '게이트 통과 훅은 1회만');
    expect(drainCalls, 1);
  });

  test('F18: server mode starts WsService on gate pass, not before', () async {
    var wsCalls = 0;
    ReportProvider.startWsServiceHook = () async {
      wsCalls++;
      return true;
    };
    final provider = await _providerWith({
      AppPrefsKeys.appMode: 'server',
      AppPrefsKeys.baseUrl: 'http://127.0.0.1:9',
      AppPrefsKeys.apiKey: 'k',
    });
    expect(wsCalls, 0);
    await provider.onGatePassed();
    expect(wsCalls, 1);
  });
}
