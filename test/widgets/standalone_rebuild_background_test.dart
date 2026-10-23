import 'package:safetyreport/community/manifest_result.dart';
// Standalone 새 버전 첫 실행: 안내 한 번 → '확인' → 바로 메인(다시 불러오기는 백그라운드, 2026-10-11 사용자 결정).
// 이미 확인한 사용자는 안내 없이 메인으로 가고 같은 run 을 이어서 진행한다. 대시보드 진행 카드의 상태별 표시·버튼도 고정한다.
// 위젯 테스트의 FakeAsync zone 에서는 ffi 질의를 하지 않으므로 메모리 상태기계를 주입한다(상태기계 자체는
// test/community/rebuild_background_runner_test.dart·rebuild_state_test.dart).
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/rebuild/community_rebuild.dart';
import 'package:safetyreport/community/rebuild/standalone_rebuild_runner.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/screens/community_rebuild_screen.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/rebuild_progress_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/ui_harness.dart' show loadGoldenFonts;

class _MemRebuild extends CommunityRebuild {
  _MemRebuild(CommunityStore store, {this.acknowledged = false})
    : super(
        store: store,
        localDatasetId: () async => 'ds',
        sourceNamespace: () async => 'ns',
        gateFresh: () async => true,
      );

  bool acknowledged;
  int acks = 0;
  final starts = <String>[];
  int pauses = 0;
  int gapAccepts = 0;
  Completer<bool>? running;

  String memState = RebuildStates.required;
  String? memError;
  bool memListComplete = false;
  bool memExecuting = false;
  bool memWaiting = false;
  bool? busyOverride;
  DateTime? leaseExpiry;
  Completer<DateTime?>? leaseRead;
  String? memNotice;
  Map<String, int> memCounts = const {};
  bool hasJob = false;

  @override
  String get state => memState;
  @override
  bool get isExecuting => memExecuting;
  @override
  bool get isBusy => busyOverride ?? super.isBusy;
  @override
  bool get waitingForWorker => memWaiting;
  @override
  Future<DateTime?> workerLeaseExpiresAt() async =>
      leaseRead != null ? await leaseRead!.future : leaseExpiry;
  @override
  bool get stopping => false;
  @override
  String? get notice => memNotice;
  @override
  Map<String, Object?>? get job => hasJob
      ? {
          'run_id': 'run-1',
          'state': memState,
          'last_error': memError,
          'list_complete': memListComplete ? 1 : 0,
        }
      : null;
  @override
  Map<String, int> counts() => memCounts;

  @override
  Future<bool> guideAcknowledged() async => acknowledged;
  @override
  Future<void> acknowledgeGuide() async {
    acks++;
    acknowledged = true;
  }

  @override
  Future<void> load() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<bool> required() async => true;

  @override
  Future<bool> start({required String confirmedBy}) {
    starts.add(confirmedBy);
    hasJob = true;
    memExecuting = true;
    memState = RebuildStates.running;
    notifyListeners();
    running = Completer<bool>();
    return running!.future;
  }

  void finish(String state, {Map<String, int>? counts}) {
    memExecuting = false;
    memState = state;
    if (counts != null) memCounts = counts;
    notifyListeners();
    running?.complete(RebuildStates.terminalOk.contains(state));
  }

  @override
  void requestPause([String reason = 'user_paused']) => pauses++;

  @override
  Future<void> acceptGaps() async {
    gapAccepts++;
  }
}

class _ModeProvider extends ReportProvider {
  _ModeProvider({this.mode = AppMode.standalone, this.demo = false});
  final AppMode mode;
  final bool demo;
  @override
  AppMode get appMode => mode;
  @override
  bool get isStandaloneDemo => demo;
}

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late String dbPath;
  late CommunityStore store;

  setUpAll(() async {
    await loadGoldenFonts();
    tmp = await Directory.systemTemp.createTemp('rebuild_bg_widget_test');
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

  StandaloneRebuildRunner newRunner() =>
      StandaloneRebuildRunner(sink: _QuietSink());

  group('first run gate', () {
    testWidgets(
      'guide once → confirm → main at once while the reload keeps running',
      (tester) async {
        final rebuild = _MemRebuild(store);
        final runner = newRunner();
        var done = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: StandaloneRebuildGate(
              prepare: () async => rebuild,
              runner: runner,
              onDone: () => done++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(StandaloneRebuildGuideScreen), findsOneWidget);
        // 기존 안내 문구와 Standalone 사과 문장 그대로.
        expect(
          tester.widget<Text>(find.byKey(const Key('rebuildGuideText'))).data,
          communityRebuildGuideText,
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('rebuildApologyText'))).data,
          communityRebuildStandaloneApologyText,
        );
        expect(communityRebuildStandaloneApologyText, startsWith('앱 구조 개선'));
        expect(done, 0);
        expect(rebuild.starts, isEmpty);
        final confirm = find.byKey(const Key('rebuildGuideConfirm'));
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pump();
        expect(rebuild.acks, 1);
        expect(rebuild.starts, ['user']);
        expect(done, 1, reason: '완료를 기다리지 않고 메인으로 간다');
        expect(rebuild.isExecuting, isTrue);
        expect(identical(runner.current, rebuild), isTrue);
        expect(runner.visible, isTrue);
        rebuild.finish(RebuildStates.completed);
        await tester.pump();
      },
    );

    testWidgets(
      'already acknowledged + interrupted: no guide, main, same run resumes',
      (tester) async {
        final rebuild = _MemRebuild(store, acknowledged: true)
          ..hasJob = true
          ..memState = RebuildStates.paused
          ..memError = 'interrupted';
        final runner = newRunner();
        var done = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: StandaloneRebuildGate(
              prepare: () async => rebuild,
              runner: runner,
              onDone: () => done++,
            ),
          ),
        );
        // 건너뛰면 게이트는 로딩 표시만 남는다(부모가 메인으로 바꾼다) — settle 대신 몇 프레임만.
        for (var i = 0; i < 3; i++) {
          await tester.pump();
        }
        expect(find.byType(StandaloneRebuildGuideScreen), findsNothing);
        expect(done, 1);
        expect(rebuild.starts, ['resume']);
        rebuild.finish(RebuildStates.completed);
        await tester.pump();
      },
    );

    for (final (label, state, error, gaps) in [
      ('user pause', RebuildStates.paused, 'user_paused', 0),
      ('gap consent', RebuildStates.validating, null, 2),
    ]) {
      testWidgets('already acknowledged + $label: main, not auto-resumed', (
        tester,
      ) async {
        final rebuild = _MemRebuild(store, acknowledged: true)
          ..hasJob = true
          ..memState = state
          ..memError = error
          ..memListComplete = true
          ..memCounts = {'listed': 10, 'fetched': 8, 'failed_permanent': gaps};
        final runner = newRunner();
        var done = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: StandaloneRebuildGate(
              prepare: () async => rebuild,
              runner: runner,
              onDone: () => done++,
            ),
          ),
        );
        for (var i = 0; i < 3; i++) {
          await tester.pump();
        }
        expect(find.byType(StandaloneRebuildGuideScreen), findsNothing);
        expect(done, 1);
        expect(rebuild.starts, isEmpty);
        expect(runner.visible, isTrue);
      });
    }
  });

  group('progress card', () {
    Future<GlobalKey> pumpCard(
      WidgetTester tester,
      StandaloneRebuildRunner runner, {
      AppMode mode = AppMode.standalone,
      bool demo = false,
      bool dark = false,
      double width = 360,
      double scale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportProvider>.value(
          value: _ModeProvider(mode: mode, demo: demo),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: RepaintBoundary(
                  key: key,
                  child: RebuildProgressCard(runner: runner),
                ),
              ),
            ),
          ),
        ),
      );
      // 테마 전환 애니메이션이 끝나도록(진행 표시는 계속 돌아 settle 하지 않는다).
      await tester.pump(const Duration(milliseconds: 600));
      return key;
    }

    Future<void> snapshot(WidgetTester tester, GlobalKey key, String name) =>
        tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Directory.systemTemp.path}/rebuild-card-$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });

    testWidgets(
      'manifest backoff caps at five minutes without exhaustion; manual recovery',
      (tester) async {
        final rebuild = _MemRebuild(store)..busyOverride = false;
        final sink = _QuietSink();
        final runner = StandaloneRebuildRunner(
          sink: sink,
          now: tester.binding.clock.now,
        )..adopt(rebuild);
        addTearDown(runner.dispose);
        final card = await pumpCard(tester, runner);
        runner.runInBackground();
        for (var i = 0; i < 5; i++) {
          rebuild.memError = 'manifest_unavailable';
          rebuild.finish(RebuildStates.prerequisitesRequired);
          await tester.pump();
          expect(find.text('자동 재시도 대기 중'), findsOneWidget);
          if (i == 0) await snapshot(tester, card, 'retry-wait');
          expect(sink.milestones.last, contains('자동으로 다시 시도'));
          expect(
            runner.resumeIfDue(),
            isFalse,
            reason: 'gate refresh must not bypass backoff',
          );
          final delay = StandaloneRebuildRunner.prerequisiteRetryDelays[i];
          expect(runner.nextRetryAt, tester.binding.clock.now().add(delay));
          await tester.pump(delay - const Duration(milliseconds: 1));
          expect(rebuild.starts, hasLength(i + 1));
          await tester.pump(const Duration(milliseconds: 1));
          expect(rebuild.starts, hasLength(i + 2));
          // 아직 작업 Future가 끝나지 않았으면 중복 실행도 예약도 없다.
          runner.runInBackground();
          expect(rebuild.starts, hasLength(i + 2));
          expect(runner.waitingToRetry, isFalse);
        }
        rebuild.finish(RebuildStates.prerequisitesRequired);
        await tester.pump();
        expect(runner.retryStopped, isFalse);
        expect(
          runner.nextRetryAt,
          tester.binding.clock.now().add(const Duration(minutes: 5)),
        );
        expect(runner.resumeIfDue(), isFalse);
        await tester.pump(const Duration(minutes: 5));
        expect(rebuild.starts, hasLength(7));
        rebuild.finish(RebuildStates.waitingRetry);
        await tester.pump();
        await tester.tap(find.byKey(const Key('rebuildCardResume')));
        await tester.pump();
        expect(rebuild.starts, hasLength(8));
        rebuild.finish(RebuildStates.completed);
        await tester.pump();
        expect(runner.waitingToRetry, isFalse);
      },
    );

    for (final status in ManifestStatus.values.where(
      (s) => s != ManifestStatus.ok,
    )) {
      testWidgets('${status.code} schedules only temporary failures', (
        tester,
      ) async {
        final rebuild = _MemRebuild(store);
        final runner = newRunner()..adopt(rebuild);
        runner.runInBackground();
        final failure = ManifestResult(status);
        rebuild.memError = failure.jobError;
        rebuild.finish(
          failure.retryable
              ? RebuildStates.waitingRetry
              : RebuildStates.prerequisitesRequired,
        );
        await tester.pump();
        expect(runner.waitingToRetry, failure.retryable);
        await tester.pump(const Duration(seconds: 15));
        expect(rebuild.starts.length, failure.retryable ? 2 : 1);
        if (failure.retryable) {
          rebuild.memError = null;
          rebuild.finish(RebuildStates.completed);
          await tester.pump();
          expect(runner.pending, isFalse);
        }
      });
    }

    testWidgets(
      'upload contention keeps polling every fifteen seconds beyond five attempts',
      (tester) async {
        final rebuild = _MemRebuild(store);
        final runner = newRunner()..adopt(rebuild);
        runner.runInBackground();
        for (var i = 0; i < 8; i++) {
          rebuild.memError = 'manifest_busy_upload_lease';
          rebuild.finish(RebuildStates.waitingRetry);
          await tester.pump();
          expect(runner.retryStopped, isFalse);
          await tester.pump(const Duration(seconds: 14));
          expect(rebuild.starts.length, i + 1);
          await tester.pump(const Duration(seconds: 1));
          expect(rebuild.starts.length, i + 2);
        }
        rebuild.memError = null;
        rebuild.finish(RebuildStates.completed);
        await tester.pump();
        expect(runner.waitingToRetry, isFalse);
      },
    );

    testWidgets('manifest recovery automatically completes after first retry', (
      tester,
    ) async {
      final rebuild = _MemRebuild(store)..busyOverride = false;
      final sink = _QuietSink();
      final runner = StandaloneRebuildRunner(sink: sink)..adopt(rebuild);
      addTearDown(runner.dispose);
      runner.runInBackground();
      rebuild.memError = 'manifest_unavailable';
      rebuild.finish(RebuildStates.prerequisitesRequired);
      await tester.pump();
      expect(sink.milestones.single, contains('재시도 대기'));
      await tester.pump(const Duration(minutes: 1));
      expect(rebuild.starts, ['user', 'resume']);
      rebuild.memError = null;
      rebuild.busyOverride = true;
      rebuild.notifyListeners();
      rebuild.finish(RebuildStates.completed);
      await tester.pump();
      expect(runner.pending, isFalse);
      expect(runner.nextRetryAt, isNull);
      expect(sink.milestones.last, contains('완료'));
      await tester.pump(const Duration(hours: 1));
      expect(rebuild.starts, hasLength(2));
    });

    testWidgets(
      '30 minute legacy lease waits until expiry plus margin, then resumes',
      (tester) async {
        final rebuild = _MemRebuild(store);
        final runner = StandaloneRebuildRunner(
          sink: _QuietSink(),
          now: tester.binding.clock.now,
        )..adopt(rebuild);
        addTearDown(runner.dispose);
        await pumpCard(tester, runner);
        final expiry = tester.binding.clock.now().add(
          const Duration(minutes: 30),
        );
        rebuild.leaseExpiry = expiry;
        runner.runInBackground();
        rebuild.memWaiting = true;
        rebuild.finish(RebuildStates.required);
        await tester.pump();
        expect(runner.nextRetryAt, expiry.add(const Duration(seconds: 5)));
        expect(find.text('자동 재시도 대기 중'), findsOneWidget);
        await tester.pump(const Duration(minutes: 30, seconds: 4));
        expect(rebuild.starts, hasLength(1));
        await tester.pump(const Duration(seconds: 1));
        expect(rebuild.starts, hasLength(2));
        rebuild.memWaiting = false;
        rebuild.finish(RebuildStates.completed);
        await tester.pump();
        expect(runner.waitingToRetry, isFalse);
      },
    );

    testWidgets(
      'renewed worker lease is read again and exhaustion stops waiting display',
      (tester) async {
        final rebuild = _MemRebuild(store);
        final runner = StandaloneRebuildRunner(
          sink: _QuietSink(),
          maxWorkerRetries: 2,
          now: tester.binding.clock.now,
        )..adopt(rebuild);
        addTearDown(runner.dispose);
        await pumpCard(tester, runner);
        runner.runInBackground();
        for (var i = 0; i < 2; i++) {
          rebuild.memWaiting = true;
          rebuild.leaseExpiry = tester.binding.clock.now().add(
            Duration(minutes: 30 + i),
          );
          rebuild.finish(RebuildStates.required);
          await tester.pump();
          expect(
            runner.nextRetryAt,
            rebuild.leaseExpiry!.add(const Duration(seconds: 5)),
          );
          await tester.pump(Duration(minutes: 30 + i, seconds: 5));
        }
        rebuild.finish(RebuildStates.required);
        await tester.pump();
        expect(find.text('자동 재시도 대기 중'), findsNothing);
        expect(find.text('자동 재시도 중단 — 확인 필요'), findsOneWidget);
        expect(runner.waitingToRetry, isFalse);
        expect(runner.resumeIfDue(), isFalse);
      },
    );

    for (final end in ['pause', 'gaps', 'clear', 'replace', 'dispose']) {
      testWidgets('pending retry cannot resume after $end', (tester) async {
        final rebuild = _MemRebuild(store);
        final runner = newRunner()..adopt(rebuild);
        runner.runInBackground();
        rebuild.memError = 'manifest_unavailable';
        rebuild.finish(RebuildStates.prerequisitesRequired);
        await tester.pump();
        expect(runner.waitingToRetry, isTrue);
        switch (end) {
          case 'pause':
            rebuild.memError = 'user_paused';
            rebuild.memState = RebuildStates.paused;
            rebuild.notifyListeners();
          case 'gaps':
            rebuild.memState = RebuildStates.validating;
            rebuild.memCounts = {'failed_permanent': 1};
            rebuild.notifyListeners();
          case 'clear':
            runner.clear();
          case 'replace':
            runner.adopt(_MemRebuild(store));
          case 'dispose':
            runner.dispose();
        }
        await tester.pump(const Duration(hours: 1));
        expect(rebuild.starts, hasLength(1));
        expect(runner.waitingToRetry, isFalse);
        if (end != 'dispose') runner.dispose();
      });
    }

    testWidgets('late lease read cannot schedule work for a replaced scope', (
      tester,
    ) async {
      final rebuild = _MemRebuild(store)..leaseRead = Completer<DateTime?>();
      final runner = newRunner()..adopt(rebuild);
      addTearDown(runner.dispose);
      runner.runInBackground();
      rebuild.memWaiting = true;
      rebuild.finish(RebuildStates.required);
      await tester.pump();
      runner.adopt(_MemRebuild(store));
      rebuild.leaseRead!.complete(
        tester.binding.clock.now().add(const Duration(minutes: 30)),
      );
      await tester.pump();
      expect(runner.waitingToRetry, isFalse);
      await tester.pump(const Duration(hours: 1));
      expect(rebuild.starts, hasLength(1));
    });

    testWidgets('running: real counts, progress bar, pause', (tester) async {
      final rebuild = _MemRebuild(store)
        ..hasJob = true
        ..memExecuting = true
        ..memState = RebuildStates.running
        ..memListComplete = true
        ..memCounts = {
          'listed': 120,
          'fetched': 45,
          'failed_permanent': 1,
          'failed_retryable': 2,
          'pending': 72,
        };
      final runner = newRunner()..adopt(rebuild);
      for (final dark in [false, true]) {
        final key = await pumpCard(tester, runner, dark: dark);
        expect(find.text('신고 내역 다시 불러오기'), findsOneWidget);
        expect(find.text('상세 수집 중 46/120건'), findsOneWidget);
        expect(
          find.text('성공 45건 · 실패 1건 · 남은 74건 (재시도 대기 2건)'),
          findsOneWidget,
        );
        final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('rebuildCardProgress')),
        );
        expect(bar.value, closeTo(46 / 120, 1e-9));
        expect(tester.takeException(), isNull);
        await snapshot(tester, key, 'running-${dark ? 'dark' : 'light'}');
      }
      await tester.tap(find.byKey(const Key('rebuildCardPause')));
      expect(rebuild.pauses, 1);
    });

    testWidgets('large text at 360 does not overflow', (tester) async {
      final rebuild = _MemRebuild(store)
        ..hasJob = true
        ..memState = RebuildStates.failed
        ..memNotice = '전체 신고 확인에 실패했습니다. 다시 시도해 주세요.'
        ..memListComplete = true
        ..memCounts = {'listed': 120, 'fetched': 45};
      final runner = newRunner()..adopt(rebuild);
      final key = await pumpCard(tester, runner, scale: 2);
      expect(tester.takeException(), isNull);
      await snapshot(tester, key, 'failed-scale2');
    });

    testWidgets('listing phase has no fake percentage', (tester) async {
      final rebuild = _MemRebuild(store)
        ..hasJob = true
        ..memExecuting = true
        ..memState = RebuildStates.running;
      final runner = newRunner()..adopt(rebuild);
      await pumpCard(tester, runner);
      expect(find.text('전체 신고 확인 중'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('rebuildCardProgress')),
            )
            .value,
        isNull,
      );
    });

    testWidgets('failed: retry runs in the background', (tester) async {
      final rebuild = _MemRebuild(store)
        ..hasJob = true
        ..memState = RebuildStates.failed
        ..memNotice = '전체 신고 확인에 실패했습니다. 다시 시도해 주세요.';
      final runner = newRunner()..adopt(rebuild);
      await pumpCard(tester, runner);
      expect(find.text('실패 — 다시 시도할 수 있습니다'), findsOneWidget);
      expect(find.text('전체 신고 확인에 실패했습니다. 다시 시도해 주세요.'), findsOneWidget);
      await tester.tap(find.text('다시 시도'));
      await tester.pump();
      expect(rebuild.starts, ['resume']);
      expect(find.byKey(const Key('rebuildCardPause')), findsOneWidget);
      rebuild.finish(RebuildStates.completed);
      await tester.pump();
    });

    testWidgets('paused by the user: resume button', (tester) async {
      final rebuild = _MemRebuild(store)
        ..hasJob = true
        ..memState = RebuildStates.paused
        ..memError = 'user_paused';
      final runner = newRunner()..adopt(rebuild);
      await pumpCard(tester, runner);
      expect(find.text('일시정지됨'), findsOneWidget);
      await tester.tap(find.text('이어서 진행'));
      await tester.pump();
      expect(rebuild.starts, ['resume']);
      rebuild.finish(RebuildStates.completed);
      await tester.pump();
    });

    testWidgets('gaps need explicit consent through a dialog', (tester) async {
      final rebuild = _MemRebuild(store)
        ..hasJob = true
        ..memState = RebuildStates.validating
        ..memListComplete = true
        ..memCounts = {'listed': 10, 'fetched': 8, 'failed_permanent': 2};
      final runner = newRunner()..adopt(rebuild);
      await pumpCard(tester, runner);
      expect(find.text('가져오지 못한 신고 2건 — 확인 필요'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rebuildCardAcceptGaps')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(rebuild.gapAccepts, 0);
      await tester.tap(find.byKey(const Key('rebuildCardAcceptGaps')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('확인하고 마무리'));
      await tester.pumpAndSettle();
      expect(rebuild.gapAccepts, 1);
    });

    testWidgets('completed with gaps stays until dismissed', (tester) async {
      final rebuild = _MemRebuild(store)
        ..hasJob = true
        ..memState = RebuildStates.completedWithGaps
        ..memListComplete = true
        ..memCounts = {'listed': 10, 'fetched': 8, 'failed_permanent': 2};
      final runner = newRunner()..adopt(rebuild);
      final key = await pumpCard(tester, runner);
      expect(find.text('완료 · 가져오지 못한 신고 2건은 기존 자료 유지'), findsOneWidget);
      await snapshot(tester, key, 'gaps-light');
      await tester.tap(find.byKey(const Key('rebuildCardDismiss')));
      await tester.pump();
      expect(find.byKey(const Key('rebuildProgressCard')), findsNothing);
    });

    testWidgets('details open the existing status screen', (tester) async {
      final rebuild = _MemRebuild(store)
        ..hasJob = true
        ..memState = RebuildStates.paused
        ..memError = 'interrupted';
      final runner = newRunner()..adopt(rebuild);
      await pumpCard(tester, runner);
      await tester.tap(find.text('자세히'));
      await tester.pumpAndSettle();
      expect(find.byType(CommunityRebuildScreen), findsOneWidget);
    });

    for (final (mode, demo) in [
      (AppMode.server, false),
      (AppMode.standalone, true),
    ]) {
      testWidgets('hidden for ${mode.name}${demo ? ' demo' : ''}', (
        tester,
      ) async {
        final rebuild = _MemRebuild(store)
          ..hasJob = true
          ..memState = RebuildStates.paused;
        final runner = newRunner()..adopt(rebuild);
        await pumpCard(tester, runner, mode: mode, demo: demo);
        expect(find.byKey(const Key('rebuildProgressCard')), findsNothing);
      });
    }
  });
}

class _QuietSink extends RebuildNotificationSink {
  final milestones = <String>[];
  @override
  Future<void> progress(
    String title,
    String message,
    int? current,
    int? total,
  ) async {}
  @override
  Future<void> milestone(String title, String body) async =>
      milestones.add('$title|$body');
}
