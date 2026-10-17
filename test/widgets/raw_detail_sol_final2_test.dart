// Sol final2 재현 2건(검색 이동 취소·공유 쓰기 실패 정리).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/screens/raw_detail_view_screen.dart';
import 'package:safetyreport/services/api_service.dart';
import 'package:safetyreport/theme/app_theme.dart';

class _FakeSource implements RawDetailSource {
  Future<RawDetailData> Function(String id)? loadBehavior;

  _FakeSource({this.loadBehavior});

  @override
  bool get isStandalone => true;

  @override
  Future<RawDetailData> load(String reportId) {
    final behavior = loadBehavior;
    if (behavior != null) return behavior(reportId);
    throw const RawDetailMissing();
  }

  @override
  Future<String?> rewriteFile(
    String reportId,
    Map<String, dynamic> sanitized,
  ) async => '/tmp/$reportId.json';

  @override
  Future<void> shareFile(String reportId, String pretty) async {}
}

RawDetailData _twoTargetData() {
  final buf = StringBuffer('{\n');
  for (var i = 0; i < 3000; i++) {
    final value = i == 100
        ? 'ZZAAA-EARLY-100'
        : (i == 2500 ? 'ZZBBB-LATE-2500' : 'padding value $i');
    buf.write('  "k${i.toString().padLeft(4, '0')}": "$value"');
    buf.write(i == 2999 ? '\n' : ',\n');
  }
  buf.write('}');
  return RawDetailData(pretty: buf.toString(), sanitized: const {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugRawShareTempDir = null;
    debugRawShareHook = null;
    debugRawShareFileWrite = null;
  });

  tearDown(() {
    debugRawShareTempDir = null;
    debugRawShareHook = null;
    debugRawShareFileWrite = null;
  });

  testWidgets('먼 줄로 이동 중 검색어 변경하면 새 대상 줄에 도달한다', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: RawDetailViewScreen(
          reportId: '90000001',
          source: _FakeSource(loadBehavior: (_) async => _twoTargetData()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 먼 줄(2500번대) 일치로 이동을 시작한다 — 완료까지 펌프하지 않아 체인이
    // 진행 중이게 둔다.
    await tester.enterText(find.byType(TextField), 'ZZBBB-LATE-2500');
    await tester.pump();
    expect(find.text('1개 중 1번째'), findsOneWidget);
    await tester.tap(find.byTooltip('다음 일치'));
    // 이동 체인이 몇 프레임 진행되게 둔다(완료까지는 기다리지 않음).
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 검색어를 바꾸면 이전 체인은 취소되고 새 대상(100번대)으로 이동한다.
    await tester.enterText(find.byType(TextField), 'ZZAAA-EARLY-100');
    await tester.pump();
    expect(find.text('1개 중 1번째'), findsOneWidget);
    await tester.pumpAndSettle();
    const earlyLine = '"k0100": "ZZAAA-EARLY-100"';
    expect(find.textContaining(earlyLine), findsOneWidget);
  });

  test('공유 파일 쓰기가 실패해도 폴더와 활성 기록이 남지 않는다', () async {
    final dir = Directory.systemTemp.createTempSync('sr_sol_final2_write_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    debugRawShareTempDir = () async => dir;
    debugRawShareFileWrite = (file, content) async {
      throw const FileSystemException('쓰기 실패 주입');
    };

    await expectLater(
      sharePrettyRawJson('90000001', '{"a":1}'),
      throwsA(isA<FileSystemException>()),
    );

    // 하위 폴더가 남지 않는다.
    final leftovers = dir
        .listSync()
        .whereType<Directory>()
        .where((e) => e.path.contains('raw_share_90000001_'))
        .toList();
    expect(leftovers, isEmpty);
    // 활성 경로 기록이 남지 않아 화면 종료 정리도 정상 동작한다.
    for (final e in dir.listSync()) {
      expect(debugRawShareDirIsActive(e.path), isFalse);
    }
    await cleanupRawShareTempFile('90000001');
    expect(
      dir
          .listSync()
          .whereType<Directory>()
          .where((e) => e.path.contains('raw_share_90000001_')),
      isEmpty,
    );
  });
}
