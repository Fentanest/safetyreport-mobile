// 초기화 크롤링을 이 기기에서 판정·실행하는가 — Standalone 이고 데모가 아닐 때만(Sol 검토 4, 2026-09-27).
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/main.dart' show rebuildAppliesOnDevice;
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';

class _Provider extends ReportProvider {
  _Provider(this.mode, {this.demo = false});
  final AppMode mode;
  final bool demo;

  @override
  AppMode get appMode => mode;

  @override
  bool get isStandaloneDemo => demo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only a real standalone account runs the rebuild on the device', () {
    expect(rebuildAppliesOnDevice(_Provider(AppMode.standalone)), isTrue);
    expect(rebuildAppliesOnDevice(_Provider(AppMode.standalone, demo: true)), isFalse,
        reason: '데모 로그인이 시드한 신고로 초기화 대상이 되지 않는다');
    expect(rebuildAppliesOnDevice(_Provider(AppMode.server)), isFalse, reason: 'Client 는 서버가 판정한다');
  });
}
