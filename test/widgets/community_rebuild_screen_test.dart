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
import 'package:safetyreport/services/community_server_link_service.dart';
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

/// 이전 버전 DB 를 비운 기존 사용자(2026-09-26).
class _LegacyMemoryRebuild extends _MemoryRebuild {
  _LegacyMemoryRebuild(super.store);

  @override
  Map<String, Object?>? get legacyReset =>
      {'from_version': 10, 'backup': '/data/standalone_reports.db.legacy_v10.1.bak'};
}

/// 서버 상태를 돌려주는 가짜 Client.
class _FakeServerClient extends CommunityServerRebuildClient {
  const _FakeServerClient(this.data);
  final Map<String, dynamic> data;

  @override
  Future<CommunityGateLinkResult> fetch(String baseUrl, String apiKey, String? token) async =>
      CommunityGateLinkResult.success(data);
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

  testWidgets('a legacy-reset user sees that the old DB was backed up and not carried over', (tester) async {
    final rebuild = _LegacyMemoryRebuild(store);
    addTearDown(rebuild.dispose);
    await tester.pumpWidget(MaterialApp(home: CommunityRebuildScreen(rebuild: rebuild)));
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.byKey(const Key('rebuildPreservedText'))).data!;
    expect(text, contains('이전 버전 DB 는 이번 업데이트에서 새 구조로 옮기지 않았습니다'));
    expect(text, contains('/data/standalone_reports.db.legacy_v10.1.bak'));
    expect(text, isNot(contains(communityRebuildPreservedText)));
  });

  testWidgets('an existing user sees the usual preserved items', (tester) async {
    final rebuild = _MemoryRebuild(store);
    addTearDown(rebuild.dispose);
    await tester.pumpWidget(MaterialApp(home: CommunityRebuildScreen(rebuild: rebuild)));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('rebuildPreservedText'))).data, communityRebuildPreservedText);
  });

  testWidgets('client mode leaves at once when the server needs no rebuild', (tester) async {
    var done = 0;
    await tester.pumpWidget(MaterialApp(
      home: CommunityRebuildScreen(
        isClient: true,
        serverClient: const _FakeServerClient({'required': false, 'state': 'completed'}),
        onDone: () async => done++,
      ),
    ));
    await tester.pumpAndSettle();
    expect(done, 1);
  });

  testWidgets('client mode stays and shows the legacy notice when the server still needs it', (tester) async {
    var done = 0;
    await tester.pumpWidget(MaterialApp(
      home: CommunityRebuildScreen(
        isClient: true,
        serverClient: const _FakeServerClient({
          'required': true,
          'state': 'required',
          'legacy_reset': {'from_version': 0, 'backup': '/data/backups/legacy_v0_20260926_000000.db'},
        }),
        onDone: () async => done++,
      ),
    ));
    await tester.pumpAndSettle();
    expect(done, 0);
    expect(tester.widget<Text>(find.byKey(const Key('rebuildPreservedText'))).data,
        contains('/data/backups/legacy_v0_20260926_000000.db'));
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
