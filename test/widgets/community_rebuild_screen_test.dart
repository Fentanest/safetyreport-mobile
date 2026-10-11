// 초기화 화면 — 안내 문구·확인·진행·완료.
//
// 상태기계 자체는 test/community/rebuild_state_test.dart(일반 테스트)에서 검증한다.
// 위젯 테스트의 FakeAsync zone 에서는 ffi 질의를 하지 않으므로,
// 화면에 메모리 상태기계를 주입한다.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:safetyreport/theme/app_theme.dart';
import '../support/ui_harness.dart' show loadGoldenFonts;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../community/fake_account.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:safetyreport/screens/community_rebuild_screen.dart';
import 'package:safetyreport/screens/community_onboarding_screen.dart';
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
  Map<String, int> counts() => {
    'fetched': 3,
    'failed_permanent': 0,
    'orphan_preserved': 1,
  };

  @override
  Future<void> load() async {}

  @override
  Future<void> refresh() async {}

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
  Map<String, Object?>? get legacyReset => {
    'from_version': 10,
    'backup': '/data/standalone_reports.db.legacy_v10.1.bak',
  };
}

/// 서버 상태를 돌려주는 가짜 Client.
class _FakeServerClient extends CommunityServerRebuildClient {
  const _FakeServerClient(this.data);
  final Map<String, dynamic> data;

  @override
  Future<CommunityGateLinkResult> fetch(
    String baseUrl,
    String apiKey,
    String? token,
  ) async => CommunityGateLinkResult.success(data);
}

/// 시작을 받아들이면 서버 상태가 running 으로 바뀌는 서버(2026-10-11: 시작 뒤 바로 메인으로).
class _StartingServerClient extends CommunityServerRebuildClient {
  int starts = 0;
  @override
  Future<CommunityGateLinkResult> fetch(
    String baseUrl,
    String apiKey,
    String? token,
  ) async => CommunityGateLinkResult.success({
    'required': true,
    'state': 'required',
  });

  @override
  Future<CommunityGateLinkResult> start(
    String baseUrl,
    String apiKey,
    String? token,
  ) async {
    starts++;
    return CommunityGateLinkResult.success({
      'required': true,
      'state': 'running',
    });
  }
}

class _PermissionServerClient extends CommunityServerRebuildClient {
  bool allowed = false;
  @override
  Future<CommunityGateLinkResult> fetch(
    String baseUrl,
    String apiKey,
    String? token,
  ) async => allowed
      ? CommunityGateLinkResult.success({
          'required': false,
          'state': 'completed',
        })
      : CommunityGateLinkResult.parse(403, '{"code":"permission_required"}');
}

class _RecoveryServerClient extends CommunityServerRebuildClient {
  _RecoveryServerClient(this.code, {this.failOnFetch = false});
  final String code;
  final bool failOnFetch;
  bool recovered = false;
  int fetches = 0;
  CommunityGateLinkResult failure() => CommunityGateLinkResult.parse(
    code == 'user_token_required' ? 403 : 503,
    '{"code":"$code"}',
  );
  @override
  Future<CommunityGateLinkResult> fetch(
    String base,
    String key,
    String? token,
  ) async {
    fetches++;
    return failOnFetch && !recovered
        ? failure()
        : CommunityGateLinkResult.success({
            'required': !recovered,
            'state': recovered ? 'completed' : 'required',
          });
  }

  @override
  Future<CommunityGateLinkResult> start(
    String base,
    String key,
    String? token,
  ) async => failure();
}

class _RecoveryAuth extends StubAuthService {
  @override
  Future<void> load() async {}
}

class _ProgressRebuild extends _MemoryRebuild {
  _ProgressRebuild(super.store);
  bool active = false;
  bool listComplete = false;
  int refreshes = 0;
  int pauses = 0;
  @override
  String get state => active ? RebuildStates.running : RebuildStates.paused;
  @override
  bool get isExecuting => active;
  @override
  Map<String, Object?> get job => {
    'state': state,
    'list_complete': listComplete ? 1 : 0,
    'backup_ref': '/fixture/backups/pre-rebuild-original.db',
    'updated_at': '2026-10-08T00:00:00Z',
  };
  @override
  Map<String, int> counts() => {
    'fetched': 12,
    'pending': 8,
    'failed_permanent': 0,
  };
  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  void requestPause([String reason = 'user_paused']) {
    pauses++;
  }
}

void main() {
  sqfliteFfiInit();

  for (final onFetch in [false, true]) {
    for (final code in ['user_token_required', 'cloud_unavailable']) {
      testWidgets('Client $code recovery from ${onFetch ? 'fetch' : 'start'}', (
        tester,
      ) async {
        final client = _RecoveryServerClient(code, failOnFetch: onFetch);
        var done = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: CommunityRebuildScreen(
              isClient: true,
              serverClient: client,
              auth: _RecoveryAuth(),
              onDone: () async => done++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (!onFetch) {
          await tester.ensureVisible(find.text('확인 — 초기화 크롤링 시작'));
          await tester.tap(find.text('확인 — 초기화 크롤링 시작'));
          await tester.pumpAndSettle();
        }
        expect(find.text('확인 — 초기화 크롤링 시작'), findsNothing);
        final login = code == 'user_token_required';
        expect(
          find.textContaining(login ? '커뮤니티 계정으로 다시 로그인' : '잠시 후 다시 시도'),
          findsOneWidget,
        );
        final button = find.text(login ? '커뮤니티 로그인 화면으로 이동' : '다시 시도');
        await tester.ensureVisible(button);
        client.recovered = true;
        await tester.tap(button);
        await tester.pumpAndSettle();
        if (login) {
          expect(find.byType(CommunityOnboardingScreen), findsOneWidget);
        } else {
          expect(client.fetches, 2);
          expect(done, 1);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  late Directory tmp;
  late String dbPath;
  late CommunityStore store;

  // 실제 open/close 만 하고 질의는 하지 않는다(위젯 테스트 종료 보장).
  setUpAll(() async {
    await loadGoldenFonts();
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

  testWidgets(
    'running list has no false completion check, pause is connected and resume refreshes',
    (tester) async {
      final rebuild = _ProgressRebuild(store)..active = true;
      addTearDown(rebuild.dispose);
      await tester.pumpWidget(
        MaterialApp(home: CommunityRebuildScreen(rebuild: rebuild)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('성공 12건'), findsOneWidget);
      final listRow = find.ancestor(
        of: find.text('전체 신고 확인'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: listRow, matching: find.byIcon(Icons.sync)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: listRow, matching: find.byIcon(Icons.check_circle)),
        findsNothing,
      );
      await tester.ensureVisible(find.text('일시정지'));
      await tester.tap(find.text('일시정지'));
      expect(rebuild.pauses, 1);
      final before = rebuild.refreshes;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(rebuild.refreshes, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    for (final width in [360.0, 412.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('recovery renders dark=$dark width=$width scale=$scale', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final rebuild = _ProgressRebuild(store);
          addTearDown(rebuild.dispose);
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: key,
                child: CommunityRebuildScreen(rebuild: rebuild),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('이어서 진행'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, '이어서 진행'),
                )
                .onPressed,
            isNotNull,
          );
          final semantics = tester.ensureSemantics();
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          semantics.dispose();
          if (width == 360 && scale == 2) {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final picture = await boundary.toImage();
              final bytes = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '/tmp/rebuild-recovery-${dark ? 'dark' : 'light'}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              picture.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }

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
    expect(find.textContaining('바뀐 기준을 반영하기 위해'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, '확인 — 초기화 크롤링 시작');
    expect(confirm, findsOneWidget);
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(rebuild.starts, 1);
    expect(rebuild.state, RebuildStates.completed);
    expect(done, 1);
  });

  testWidgets(
    'a legacy-reset user sees that the old DB was backed up and not carried over',
    (tester) async {
      final rebuild = _LegacyMemoryRebuild(store);
      addTearDown(rebuild.dispose);
      await tester.pumpWidget(
        MaterialApp(home: CommunityRebuildScreen(rebuild: rebuild)),
      );
      await tester.pumpAndSettle();
      final text = tester
          .widget<Text>(find.byKey(const Key('rebuildPreservedText')))
          .data!;
      expect(text, contains('이전 버전 DB 는 이번 업데이트에서 새 구조로 옮기지 않았습니다'));
      expect(text, contains('/data/standalone_reports.db.legacy_v10.1.bak'));
      expect(text, isNot(contains(communityRebuildPreservedText)));
    },
  );

  testWidgets('an existing user sees the usual preserved items', (
    tester,
  ) async {
    final rebuild = _MemoryRebuild(store);
    addTearDown(rebuild.dispose);
    await tester.pumpWidget(
      MaterialApp(home: CommunityRebuildScreen(rebuild: rebuild)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('rebuildPreservedText'))).data,
      communityRebuildPreservedText,
    );
  });

  testWidgets(
    'permission denial shows recovery instead of rebuild, then retries',
    (tester) async {
      var done = 0;
      final client = _PermissionServerClient();
      await tester.pumpWidget(
        MaterialApp(
          home: CommunityRebuildScreen(
            isClient: true,
            serverClient: client,
            auth: StubAuthService(),
            onDone: () async => done++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('서버 권한 확인'), findsOneWidget);
      expect(find.textContaining('PC 앱 설정 > 4. 커뮤니티 계정'), findsOneWidget);
      expect(find.text('확인 — 초기화 크롤링 시작'), findsNothing);
      expect(find.textContaining('바뀐 기준을 반영하기 위해'), findsNothing);
      expect(find.textContaining('HTTP 403'), findsNothing);
      expect(done, 0);
      client.allowed = true;
      await tester.tap(find.text('상태 다시 확인'));
      await tester.pumpAndSettle();
      expect(done, 1);
      expect(find.text('서버 권한 확인'), findsNothing);
    },
  );

  testWidgets('client mode leaves at once when the server needs no rebuild', (
    tester,
  ) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityRebuildScreen(
          isClient: true,
          serverClient: const _FakeServerClient({
            'required': false,
            'state': 'completed',
          }),
          onDone: () async => done++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(done, 1);
  });

  testWidgets(
    'client mode stays and shows the legacy notice when the server still needs it',
    (tester) async {
      var done = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CommunityRebuildScreen(
            isClient: true,
            serverClient: const _FakeServerClient({
              'required': true,
              'state': 'required',
              'legacy_reset': {
                'from_version': 0,
                'backup': '/data/backups/legacy_v0_20260926_000000.db',
              },
            }),
            onDone: () async => done++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(done, 0);
      expect(
        tester.widget<Text>(find.byKey(const Key('rebuildPreservedText'))).data,
        contains('/data/backups/legacy_v0_20260926_000000.db'),
      );
    },
  );

  testWidgets('client mode shows server wording', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CommunityRebuildScreen(isClient: true)),
    );
    await tester.pump();
    expect(find.textContaining('연결된 서버가 저장된 신고를 안전신문고에서 한 번 다시 불러옵니다'), findsOneWidget);
  });

  testWidgets('both modes show the update notice with the apology line', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: CommunityRebuildScreen(isClient: true)),
    );
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('rebuildApologyText'))).data,
      '서버 사양 개선에 따른 추가적인 불가피한 조치입니다. 불편을 드려 죄송합니다.',
    );
    expect(find.text('신고 내역 다시 불러오기'), findsOneWidget);
  });

  testWidgets('standalone says app structure instead of server spec', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: CommunityRebuildScreen(rebuild: _MemoryRebuild(store))),
    );
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('rebuildApologyText'))).data,
      '앱 구조 개선에 따른 추가적인 불가피한 조치입니다. 불편을 드려 죄송합니다.',
    );
  });

  testWidgets(
    'client mode goes to main as soon as the server accepts the start',
    (tester) async {
      var done = 0;
      final client = _StartingServerClient();
      await tester.pumpWidget(
        MaterialApp(
          home: CommunityRebuildScreen(
            isClient: true,
            serverClient: client,
            auth: StubAuthService(),
            onDone: () async => done++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(done, 0);
      await tester.ensureVisible(find.text('확인 — 초기화 크롤링 시작'));
      await tester.tap(find.text('확인 — 초기화 크롤링 시작'));
      await tester.pumpAndSettle();
      expect(client.starts, 1);
      expect(done, 1);
    },
  );
}
