// 초기화 화면 — 안내 문구·확인·진행·완료.
//
// 상태기계 자체는 test/community/rebuild_state_test.dart(일반 테스트)에서 검증한다.
// 위젯 테스트의 FakeAsync zone 에서는 ffi 질의를 하지 않으므로,
// 화면에 메모리 상태기계를 주입한다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:safetyreport/screens/community_rebuild_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 화면이 쓰는 진입점만 가진 메모리 상태기계. DB 를 건드리지 않는다.
class _MemoryRebuild extends CommunityRebuild {
  _MemoryRebuild(CommunityStore store)
      : super(
          store: store,
          localDatasetId: () async => 'ds',
          sourceNamespace: () async => 'ns',
          gateFresh: () async => true,
        );

  String _state = RebuildStates.required;
  int starts = 0;

  @override
  String get state => _state;

  @override
  Map<String, Object?>? get job => {
        'state': _state,
        'backup_ref': 'backups/pre-rebuild-run.db',
        'counts_json': '{"fetched":3,"failed_permanent":0,"orphan_preserved":1}',
      };

  @override
  Map<String, int> counts() =>
      {'fetched': 3, 'failed_permanent': 0, 'orphan_preserved': 1};

  @override
  Future<void> load() async {}

  @override
  Future<bool> required() async => _state == RebuildStates.required;

  @override
  Future<bool> start({required String confirmedBy}) async {
    starts++;
    _state = RebuildStates.completed;
    notifyListeners();
    return true;
  }

  @override
  Future<void> resume() async {}

  @override
  Future<void> acceptGaps() async {}
}

void main() {
  sqfliteFfiInit();

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;

  // 실제 open/close 만 하고 질의는 하지 않는다(위젯 테스트 종료 보장).
  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('rebuild_screen_test');
    dbPath = '${tmp.path}/community.db';
    store = await CommunityStore.open(
      path: dbPath,
      factory: databaseFactoryFfi,
    );
  });

  tearDownAll(() async {
    CommunityRebuildGuard.active = false;
    await CommunityStore.closeForTest(dbPath);
    await tmp.delete(recursive: true);
  });

  testWidgets('guide, confirm, progress and done', (tester) async {
    final rebuild = _MemoryRebuild(store);
    addTearDown(rebuild.dispose);
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityRebuildScreen(
          rebuild: rebuild,
          onDone: () async {
            done++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('초기화 크롤링을 한 번 진행해야 합니다'), findsOneWidget);
    final confirm = find.widgetWithText(
      FilledButton,
      '확인 — 초기화 크롤링 시작',
    );
    expect(confirm, findsOneWidget);
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(rebuild.starts, 1);
    expect(rebuild.state, RebuildStates.completed);
    expect(done, 1);
  });

  testWidgets('client mode shows server wording', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CommunityRebuildScreen(isClient: true),
      ),
    );
    await tester.pump();
    expect(
      find.textContaining('연결된 서버에서 초기화 크롤링을 진행합니다'),
      findsOneWidget,
    );
  });
}
