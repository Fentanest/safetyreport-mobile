import 'services/client_compatibility.dart';
import 'services/server_contract.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:workmanager/workmanager.dart';

import 'screens/dashboard_screen.dart';
import 'screens/report_list_screen.dart';
import 'screens/report_management_screen.dart';
import 'screens/statistics_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/cloud_unavailable_screen.dart';
import 'screens/official_account_start_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/permission_screen.dart';
import 'screens/community_onboarding_screen.dart';
import 'screens/community_rebuild_screen.dart';
import 'models/app_mode.dart';
import 'models/app_theme_mode.dart';
import 'models/duplicate_group.dart';
import 'models/report.dart';
import 'providers/report_provider.dart';
import 'providers/notification_history_provider.dart';
import 'services/background_login_check.dart';
import 'services/agency_registry.dart';
import 'services/community_auth_link_channel.dart';
import 'services/community_auth_service.dart';
import 'services/local_db_service.dart';
import 'services/permission_service.dart';
import 'services/server_connection_service.dart';
import 'community/community_store.dart';
import 'community/community_wiring.dart';
import 'community/gate/community_gate.dart';
import 'community/rebuild/community_rebuild.dart';
import 'services/pending_changes_store.dart';
import 'services/secure_storage_migration.dart';
import 'screens/secure_storage_recovery_screen.dart';
import 'services/review_prompt_service.dart';
import 'services/sync_engine.dart' show ChangeType, SyncEngine;
import 'server_palette.dart';
import 'navigation/app_routes.dart';
import 'navigation/main_tabs.dart';
import 'navigation/native_call_router.dart';
import 'theme/app_theme.dart';
import 'theme/sr_colors.dart';
import 'widgets/status_badge.dart';
import 'widgets/duplicate_group_detail_sheet.dart';
import 'widgets/report_detail_sheet.dart';
import 'widgets/maintenance_status_bar.dart';
import 'widgets/community_account_card.dart';
import 'theme/sr_tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Kotlin → Dart 호출(알림 탭 이동·동기화 서비스 중지)은 화면과 무관하게 앱 루트에서 한 번 받는다(SQ-B05).
  // 이동 요청은 메인 화면이 붙을 때까지 보관하고, Kotlin 은 dartReady 를 받은 뒤 보류한 요청을 보낸다.
  unawaited(NativeCallRouter.instance.start());
  await ServerContract.loadProductVersion();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 보안 저장소 v9 → v10 이관을 앱 시작 때 끝낸다(다른 코드가 보안 저장소를 열기 전에, 백그라운드 작업은 이 표시 뒤에만 연다).
  // 확인되지 않으면 평소 화면으로 들어가지 않는다 — 로그인·토큰 갱신·연결 등록·설정 초기화가 폴백 상태의 저장소에 쓰지 않게.
  if (!await SecureStorageMigration.ensureMigrated()) {
    runApp(const SecureStorageRecoveryApp());
    return;
  }
  // 아래 네 준비는 서로 기다릴 필요가 없어 함께 기다린다(SQ-P12). 순서가 필요한 보안 저장소 이관은 위에서 먼저 끝냈다.
  // 각 단계의 실패 처리는 예전과 같다(카카오 세션 복원 실패만 시작을 멈춘다).
  final communityAuth = CommunityAuthService.instance;
  final communityStoreFuture = CommunityStore.open().then<CommunityStore?>(
    (store) => store,
    onError: (Object _) => null,
  );
  await Future.wait<void>([
    // Standalone 하루 1회 로그인 점검(BackgroundLoginCheck). 등록/해제는 ReportProvider 가 모드에 따라 한다.
    () async {
      try {
        await Workmanager().initialize(backgroundTaskDispatcher);
      } catch (_) {}
    }(),
    // 보안 저장소의 기존 카카오 세션을 게이트 생성·첫 검사 전에 복원한다.
    // 그렇지 않으면 재실행 때 기본 disconnected 상태를 보고 연결 화면을 다시 연다.
    communityAuth.load(),
    // 기관·지역 registry 스냅샷(통계·표시용 현행명). 실패해도 앱은 기존 normalize 로 동작한다.
    () async {
      try {
        await AgencyRegistry.ensureLoaded();
      } catch (_) {}
    }(),
    communityStoreFuture,
  ]);
  // 커뮤니티 계정(Standalone) 로그인 복귀 링크 — SetupScreen·설정 등 어느 화면에서든 받도록 앱 시작 때 등록.
  // 게이트 중에도 수신한다(게이트가 끝나면 상태가 반영된다). 세션 복원(load)이 끝난 뒤에 받는다.
  final reportProvider = ReportProvider();
  // 저장된 데모 모드를 첫 게이트 검사·인증 링크 처리 전에 확정한다.
  await reportProvider.init();
  CommunityAuthLinkChannel.start((link) async {
    if (!reportProvider.isStandaloneDemo) {
      await communityAuth.handleCallbackLink(link);
    }
  });
  final CommunityStore? communityStore = await communityStoreFuture;
  final gate = CommunityGate(
    auth: communityAuth,
    store: communityStore,
    datasetGeneration: () => reportProvider.accountConfigEpoch,
    checkAccountChangeComplete: () async {
      if (reportProvider.isConfigured) {
        await LocalDbService.requireAccountChangeComplete();
      }
    },
    officialAccountId: () async => reportProvider.standaloneUsername.isEmpty
        ? null
        : reportProvider.standaloneUsername,
    // 데모는 Standalone 화면이지만 writer 가 아니다(연결 등록·업로드 없음).
    appMode: () =>
        reportProvider.isStandaloneDemo ? 'demo' : reportProvider.appMode.name,
  );
  reportProvider.officialAccountNeedsReset = gate.officialAccountNeedsReset;
  reportProvider.releaseOfficialAccount = gate.releaseOfficialAccount;
  // 초기화 크롤링이 필요하거나 진행 중이면 일반 동기화(수동·공유 대기열 처리)를 시작하지 않는다(PC 크롤 시작 409 와 같음).
  // 초기화 화면보다 먼저 도는 게이트 통과 직후 처리도 여기서 막힌다.
  SyncEngine.rebuildBlocks = () async {
    if (!rebuildAppliesOnDevice(reportProvider)) return false;
    final store = communityStore ?? await CommunityStore.open();
    return standaloneRebuild(store, reportProvider).required();
  };
  // 서버 연결은 루트에서 PC 버전 3 이상을 확인한 뒤 시작한다.
  // 모드 전환(Client·데모 → Standalone 등) 뒤에는 그 기기 DB 의 주인을 다시 확인한다.
  reportProvider.addListener(gate.onAppModeChanged);
  if (communityStore != null) {
    CommunityWiring.wire(communityGate: gate, store: communityStore);
  }
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: reportProvider),
        ChangeNotifierProvider.value(value: gate),
        ChangeNotifierProvider(
          create: (_) => NotificationHistoryProvider()..load(),
        ),
      ],
      child: const SafetyReportApp(),
    ),
  );
}

class SafetyReportApp extends StatefulWidget {
  const SafetyReportApp({super.key, this.serverVersionCheck});

  /// 위젯 테스트에서는 네트워크 없이 버전 검사 결과를 주입한다.
  final Future<ServerConnectionResult> Function(String baseUrl, String apiKey)?
  serverVersionCheck;

  @override
  State<SafetyReportApp> createState() => _SafetyReportAppState();
}

class _SafetyReportAppState extends State<SafetyReportApp> {
  late final CommunityGate _gate;
  bool _gateWasOpen = false;
  AppMode? _initialModeChoice;
  Future<ServerConnectionResult>? _serverVersionFuture;
  String? _checkedBaseUrl;
  String? _checkedApiKey;

  Future<ServerConnectionResult> _checkServer(ReportProvider provider) {
    if (_serverVersionFuture != null &&
        _checkedBaseUrl == provider.baseUrl &&
        _checkedApiKey == provider.apiKey) {
      return _serverVersionFuture!;
    }
    _checkedBaseUrl = provider.baseUrl;
    _checkedApiKey = provider.apiKey;
    final url = provider.baseUrl;
    final key = provider.apiKey;
    return _serverVersionFuture = () async {
      ServerConnectionResult result;
      try {
        result =
            await (widget.serverVersionCheck?.call(url, key) ??
                ServerConnectionService.checkVersion(
                  baseUrl: url,
                  apiKey: key,
                ));
      } catch (_) {
        result = ServerConnectionResult.networkError(
          normalizedUrl: url,
          message: 'PC 서버 버전을 확인할 수 없습니다. 다시 확인해 주세요.',
        );
      }
      if (!result.isOk &&
          provider.appMode == AppMode.server &&
          provider.baseUrl == url &&
          provider.apiKey == key) {
        await PermissionService.stopWsService();
        if (_gate.canEnter) _returnToRoot();
      }
      return result;
    }();
  }

  void _retryServerVersion() {
    ClientCompatibility.invalidate();
    setState(() => _serverVersionFuture = null);
  }

  void _returnToRoot() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = communityAuthNavigatorKey.currentState;
      if (navigator?.canPop() == true) {
        navigator!.popUntil((route) => route.isFirst);
      }
    });
  }

  void _onCompatibilityFailure() {
    // 화면이 닫힌 뒤 온 알림이면 context 를 쓰지 않는다(SQ-B09).
    if (!mounted) return;
    final failure = ClientCompatibility.failure.value;
    final provider = context.read<ReportProvider>();
    if (failure == null ||
        provider.appMode != AppMode.server ||
        failure.normalizedUrl !=
            ServerContract.normalizeBaseUrl(provider.baseUrl)) {
      return;
    }
    provider.onGateBlocked();
    unawaited(PermissionService.stopWsService());
    _returnToRoot();
    setState(() => _serverVersionFuture = Future.value(failure));
  }

  void _onGateChanged() {
    final canEnter = _gate.canEnter;
    final provider = context.read<ReportProvider>();
    final wasOpen = _gateWasOpen;
    _gateWasOpen = canEnter;
    if (wasOpen && !canEnter && !provider.isStandaloneDemo) {
      provider.onGateBlocked();
      _returnToRoot();
    }
  }

  @override
  void initState() {
    super.initState();
    _gate = context.read<CommunityGate>();
    _gateWasOpen = _gate.canEnter;
    _gate.addListener(_onGateChanged);
    ClientCompatibility.failure.addListener(_onCompatibilityFailure);
    _gate.startPolling();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_gate.refreshNow());
    });
  }

  @override
  void dispose() {
    _gate.removeListener(_onGateChanged);
    ClientCompatibility.failure.removeListener(_onCompatibilityFailure);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 루트는 테마 설정만 보고 MaterialApp 을 다시 만든다(SQ-P01). 테마는 캐시된 같은 객체라 보간이 돌지 않는다.
    // 첫 화면 판정은 아래 Builder 가 쓰는 값이 바뀔 때만 다시 한다(목록·통계 갱신 알림은 무시).
    final themeMode = context.select<ReportProvider, ThemeMode>(
      (p) => p.themeMode.themeMode,
    );
    // 두 모드 공통 테마(D-03). 모드는 ModeBadge 로 따로 표시한다.
    return MaterialApp(
      title: '나만의 안전신문고',
      debugShowCheckedModeBanner: false,
      // 커뮤니티 로그인 복귀 뒤 계정 확인 창·안내를 어느 화면에서든 띄우기 위한 루트 키.
      navigatorKey: communityAuthNavigatorKey,
      scaffoldMessengerKey: communityAuthMessengerKey,
      builder: (context, child) =>
          context.select<ReportProvider, bool>((p) => p.isStandaloneDemo)
          ? (child ?? const SizedBox.shrink())
          : CommunityAuthPrompt(child: child ?? const SizedBox.shrink()),
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: Builder(
        builder: (context) {
          context.select<ReportProvider, Object>(
            (p) => (
              p.isInitialized,
              p.appMode,
              p.isConfigured,
              p.isStandaloneDemo,
              p.baseUrl,
              p.apiKey,
            ),
          );
          context.select<CommunityGate, Object>(
            (g) => (g.isChecked, g.canEnter, g.state.state),
          );
          final provider = context.read<ReportProvider>();
          final gate = context.read<CommunityGate>();
          if (provider.isInitialized &&
              !provider.isStandaloneDemo &&
              provider.appMode == AppMode.server &&
              provider.isConfigured) {
            return FutureBuilder<ServerConnectionResult>(
              future: _checkServer(provider),
              builder: (context, check) =>
                  _buildHome(provider, gate, check.data),
            );
          }
          return _buildHome(provider, gate, null);
        },
      ),
    );
  }

  Widget _buildHome(
    ReportProvider provider,
    CommunityGate gate,
    ServerConnectionResult? serverVersion,
  ) {
    // 최초 설정: 모드 선택 → 카카오 동의 → 공통 권한 → 해당 모드 설정.
    // 데모는 합성 자료만 쓰므로 인증·권한·서비스를 시작하지 않는다.
    if (!provider.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (provider.isConfigured) _initialModeChoice = null;
    if (provider.isStandaloneDemo) return const MainNavigationScreen();
    if (!provider.isConfigured && _initialModeChoice == null) {
      return SetupScreen(
        onModeSelected: (mode) => setState(() => _initialModeChoice = mode),
      );
    }
    if (!gate.isChecked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!gate.canEnter && gate.state.state == 'cloud_unavailable') {
      return CloudUnavailableScreen(gate: gate);
    }
    if (!gate.canEnter &&
        const {
          'official_account_mismatch',
          'official_account_taken',
          'official_account_change_required',
        }.contains(gate.state.state)) {
      return SetupScreen(
        key: const ValueKey('official-account-recovery'),
        initialMode: AppMode.standalone,
        accountRecovery: true,
        initialNotice: gate.notice ?? LocalDbService.officialResetMessage,
      );
    }
    if (!gate.canEnter) {
      return CommunityOnboardingScreen(
        gate: gate,
        // 없으면 동의를 저장하지 못한다("커뮤니티 서버 설정이 없어 동의를 저장할 수 없습니다", 2026-09-27 dev 빌드에서 발견)
        accountClient: gate.accountClient,
        onReportsWiped: provider.refreshAll,
        clientServer:
            provider.appMode == AppMode.server && serverVersion?.isOk == true
            ? (baseUrl: provider.baseUrl, apiKey: provider.apiKey)
            : null,
        onNext: () async {
          await gate.requireFresh();
        },
        onBackToModeSelection: !provider.isConfigured
            ? () => setState(() => _initialModeChoice = null)
            : null,
      );
    }
    if (!provider.isConfigured) {
      return _SetupFlow(initialMode: _initialModeChoice);
    }
    if (provider.appMode == AppMode.server) {
      if (serverVersion == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (!serverVersion.isOk) {
        return _ServerVersionBlockedScreen(
          message: serverVersion.message ?? 'PC 서버 버전을 확인할 수 없습니다.',
          onRetry: _retryServerVersion,
        );
      }
    }
    if (provider.appMode == AppMode.standalone) {
      return OfficialAccountStartScreen(
        key: ValueKey(provider.accountConfigEpoch),
        child: const _PostGateFlow(),
      );
    }
    return const _PostGateFlow();
  }
}

class _ServerVersionBlockedScreen extends StatelessWidget {
  const _ServerVersionBlockedScreen({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PC 서버 연결 확인')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.update_rounded,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: onRetry, child: const Text('다시 확인')),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SetupScreen()),
                  ),
                  child: const Text('서버 주소 또는 API 키 변경'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 게이트 통과 뒤 신규 설치 흐름: 모드 무관 권한(common) → 기존 SetupScreen.
class _SetupFlow extends StatefulWidget {
  const _SetupFlow({this.initialMode});

  final AppMode? initialMode;

  @override
  State<_SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends State<_SetupFlow> {
  bool _commonDone = false;

  @override
  Widget build(BuildContext context) {
    if (!_commonDone) {
      return PermissionScreen(
        phase: PermissionPhase.common,
        isSetup: true,
        onDone: () => setState(() => _commonDone = true),
      );
    }
    return SetupScreen(initialMode: widget.initialMode);
  }
}

/// 설정 완료 사용자 흐름: Client 서비스 시작 → 초기화(필요 시) → 메인.
class _PostGateFlow extends StatefulWidget {
  const _PostGateFlow();

  @override
  State<_PostGateFlow> createState() => _PostGateFlowState();
}

class _PostGateFlowState extends State<_PostGateFlow> {
  bool _modeDone = false;
  bool _rebuildDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.read<CommunityGate>().canEnter) {
        unawaited(context.read<ReportProvider>().onGatePassed());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_modeDone) {
      return _ModeSupplement(onDone: () => setState(() => _modeDone = true));
    }
    if (!_rebuildDone) {
      final provider = context.read<ReportProvider>();
      if (provider.appMode == AppMode.server) {
        return CommunityRebuildScreen(
          isClient: true,
          serverBaseUrl: provider.baseUrl,
          serverApiKey: provider.apiKey,
          onDone: () async {
            setState(() => _rebuildDone = true);
          },
        );
      }
      return StandaloneRebuildGate(
        onDone: () {
          if (mounted) setState(() => _rebuildDone = true);
        },
      );
    }
    return const MainNavigationScreen();
  }
}

/// WebSocket은 OS 권한이 아니라 앱 서비스다. 설정 완료 뒤 한 번 시작하고 진행한다.
class _ModeSupplement extends StatefulWidget {
  const _ModeSupplement({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_ModeSupplement> createState() => _ModeSupplementState();
}

class _ModeSupplementState extends State<_ModeSupplement> {
  late final Future<void> _startup = _start();

  Future<void> _start() async {
    final provider = context.read<ReportProvider>();
    if (provider.appMode != AppMode.server ||
        !PermissionService.supportsWsService ||
        !context.read<CommunityGate>().canEnter) {
      return;
    }
    if (!await PermissionService.isWsServiceRunning()) {
      if (mounted && context.read<CommunityGate>().canEnter) {
        await PermissionService.startWsService();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _startup,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onDone();
        });
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
    );
  }
}

/// 이 기기에서 초기화 크롤링을 판정·실행하는가: Standalone 이고 데모(심사용 합성 데이터, 별도 DB 파일)가 아닐 때만.
/// 데모는 사이트에서 다시 읽을 실제 신고가 없다 — 첫 데모 로그인이 시드한 신고 때문에 초기화 대상이 되지 않게 한다(Sol 검토 4).
/// Client 는 서버가 판정한다.
@visibleForTesting
bool rebuildAppliesOnDevice(ReportProvider provider) =>
    provider.appMode == AppMode.standalone && !provider.isStandaloneDemo;

/// Standalone 초기화 판정·실행 객체. 새 설치 판정에 개인 DB 사실(신고 수·이전 DB 를 비운 기록)을 쓴다.
/// 시작 버튼이 있는 화면만 [gateFresh] 를 넘긴다(판정만 할 때는 게이트를 확인하지 않는다).
@visibleForTesting
CommunityRebuild standaloneRebuild(
  CommunityStore store,
  ReportProvider provider, {
  Future<bool> Function()? gateFresh,
}) => CommunityRebuild(
  store: store,
  localDatasetId: store.localDatasetId,
  scopeGeneration: () => provider.datasetEpoch,
  sourceNamespace: () async {
    final id = provider.standaloneUsername;
    if (id.isEmpty) return '';
    return datasetKeyForOfficialId(id);
  },
  gateFresh: gateFresh ?? () async => false,
  personalDbPath: LocalDbService.getDbPath,
  personalDbFacts: LocalDbService.personalDbFacts,
);

/// Standalone 초기화 필요 여부 확인. 필요 없으면 메인으로 건너뛴다.
class StandaloneRebuildGate extends StatefulWidget {
  const StandaloneRebuildGate({super.key, required this.onDone, this.prepare});
  final VoidCallback onDone;

  /// 시험용 판정 주입. 없으면 커뮤니티 저장소로 초기화가 필요한지 판정한다.
  final Future<CommunityRebuild?> Function()? prepare;

  @override
  State<StandaloneRebuildGate> createState() => _StandaloneRebuildGateState();
}

class _StandaloneRebuildGateState extends State<StandaloneRebuildGate> {
  Future<CommunityRebuild?>? _future;

  /// 건너뛰기(onDone)는 한 번만, 화면이 살아 있을 때만 부른다(SQ-B13). build 는 여러 번 돌 수 있다.
  bool _skipScheduled = false;

  @override
  void initState() {
    super.initState();
    _future = widget.prepare?.call() ?? _prepare();
  }

  Future<CommunityRebuild?> _prepare() async {
    final provider = context.read<ReportProvider>();
    final gate = context.read<CommunityGate>();
    if (!rebuildAppliesOnDevice(provider)) return null;
    await LocalDbService.requireAccountChangeComplete();
    final store = await CommunityStore.open();
    final rebuild = standaloneRebuild(
      store,
      provider,
      gateFresh: () async => (await gate.requireFresh()).canEnter,
    );
    await rebuild.load();
    if (!await rebuild.required()) return null;
    return rebuild;
  }

  void _skipOnce() {
    if (_skipScheduled) return;
    _skipScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDone();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CommunityRebuild?>(
      future: _future,
      builder: (context, snap) {
        if (snap.error is ForeignDatabaseException) {
          return SetupScreen(
            initialMode: AppMode.standalone,
            initialNotice: snap.error.toString(),
            accountRecovery: true,
          );
        }
        if (snap.hasError) {
          // 저장소를 열지 못하면(테스트·손상) 초기화를 건너뛰고 메인으로 간다.
          _skipOnce();
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final rebuild = snap.data;
        if (rebuild == null) {
          _skipOnce();
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return CommunityRebuildScreen(
          rebuild: rebuild,
          onDone: () async {
            widget.onDone();
          },
        );
      },
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

/// 게이트 미충족이면 알림 탭 이동·payload 상세 열기를 무시한다 (F06).
/// Provider 가 없으면(예전 테스트) 허용으로 둔다.
bool communityNavAllowed(BuildContext context) {
  try {
    if (Provider.of<ReportProvider>(context, listen: false).isStandaloneDemo) {
      return true;
    }
    return Provider.of<CommunityGate>(context, listen: false).canEnter;
  } catch (_) {
    return true;
  }
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with WidgetsBindingObserver
    implements NativeNavTarget {
  int _selectedIndex = 0;
  String _lastQuickActionSignature = '';
  late final List<Widget?> _screenCache = List<Widget?>.filled(_tabCount, null);

  /// 하단 탭 전환·하위 탭 지정 통로(SQ-U06). 대시보드 "감시 목록 › 관리" 등이 화면을 새로 쌓지 않고 쓴다.
  late final MainTabController _tabs = MainTabController(
    onSelectTab: _selectTab,
  );

  /// 게이트 미충족이면 알림 탭 이동·payload 상세 열기를 무시한다.
  bool get _gateAllows => communityNavAllowed(context);

  /// 하단 탭 수(D-06: 7 → 5). 동기화/크롤링·파일은 [AppRoutes] 로 연다.
  static const _tabCount = MainTabs.count;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Native 의 navigateToTab 은 앱 루트 처리기가 받아 이 화면이 붙을 때까지 보관한다(SQ-B05).
    NativeCallRouter.instance.attach(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationHistoryProvider>().load();
      _checkPendingChanges();
    });
    unawaited(ReviewPromptService.recordAppOpen());
  }

  @override
  void dispose() {
    NativeCallRouter.instance.detach(this);
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  /// 하단 탭을 바꾸고 그 화면을 새로 고친다.
  void _selectTab(int index) {
    if (!mounted) return;
    final clamped = index.clamp(0, _tabCount - 1);
    setState(() => _selectedIndex = clamped);
    _refreshOnTab(clamped);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ReviewPromptService.recordAppOpen());
      _checkPendingChanges();
      _checkForegroundEvent();
      // standalone: Kotlin NotificationService 가 설정한 sync pending 플래그 확인
      if (mounted) {
        context.read<ReportProvider>().checkAutoSyncOnResume();
      }
    }
  }

  @override
  Future<void> handleNativeNavigation(NativeNavRequest request) async {
    if (!mounted || !_gateAllows) return;
    final tab = request.tab;
    final subTab = request.subTab;
    final eventType = request.eventType;
    final payloadJson = request.payloadJson;
    if (subTab != null) {
      context.read<NotificationHistoryProvider>().setPreferredTabIndex(
        subTab,
        notify: false,
      );
    }
    // 옛 하단 탭 인덱스 5(파일)·6(동기화/크롤링)은 화면을 따로 연다(Kotlin 은 그대로 6 을 보냄).
    if (tab == 5) {
      AppRoutes.openFiles(context);
    } else if (tab == 6) {
      // 런처 바로가기(quick_*)는 아래 _handleNavigationEvent 가 화면을 연 뒤 명령까지 전달한다.
      if (eventType != 'quick_sync' && eventType != 'quick_crawl') {
        AppRoutes.openCrawl(context);
      }
    } else {
      _selectTab(tab);
    }
    if (payloadJson.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openNotificationPayloadDetail(payloadJson);
      });
    }
    if (eventType.isNotEmpty && mounted) {
      await _handleNavigationEvent(eventType);
    }
  }

  Future<void> _handleNavigationEvent(String eventType) async {
    switch (eventType) {
      case 'standalone_sync':
        await context.read<ReportProvider>().checkAutoSyncOnResume();
        return;
      case 'quick_sync':
      case 'quick_crawl':
        await AppRoutes.runQuickAction(context, eventType);
        return;
    }
  }

  /// 탭 변경 시 해당 화면 새로고침.
  /// 0 대시보드, 1 신고내역, 2 신고관리, 3 통계, 4 알림 (파일·동기화/크롤링은 [AppRoutes])
  void _refreshOnTab(int index) {
    if (!mounted) return;
    final p = context.read<ReportProvider>();
    switch (index) {
      case 0:
        if (p.isConfigured) p.fetchSummary();
        break;
      case 1:
        if (p.isConfigured && p.appMode == AppMode.server) {
          p.fetchWatchlistNumbers();
        }
        break;
      case 2:
        p.fetchWatchlistNumbers();
        break;
      case 3:
        p.bumpStatsRefresh();
        break;
      case 4:
        context.read<NotificationHistoryProvider>().load();
        break;
    }
  }

  Future<void> _checkForegroundEvent() async {
    final event = await ForegroundEventStore.readAndClear();
    if (event == null || !mounted || !_gateAllows) return;
    final title = event['title']?.toString() ?? '';
    final body = event['body']?.toString() ?? '';
    final payloadJson = event['payload_json']?.toString() ?? '';
    if (title.isEmpty) return;
    if (payloadJson.isNotEmpty) {
      final payload = _decodeNotificationPayload(payloadJson);
      if (payload != null) {
        final history = context.read<NotificationHistoryProvider>();
        await history.ensureLoaded();
        if (!mounted) return;
        if (history.isPayloadRead(payload)) return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (body.isNotEmpty)
              Text(body, style: const TextStyle(fontSize: 12)),
          ],
        ),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: payloadJson.isNotEmpty ? '상세 보기' : '알림 보기',
          onPressed: () {
            setState(() => _selectedIndex = 4);
            if (payloadJson.isNotEmpty) {
              _openNotificationPayloadDetail(payloadJson);
            }
          },
        ),
      ),
    );
  }

  Map<String, dynamic>? _decodeNotificationPayload(String payloadJson) {
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  void _openNotificationPayloadDetail(String payloadJson) {
    if (!_gateAllows) return;
    final data = _decodeNotificationPayload(payloadJson);
    if (data == null) return;
    unawaited(
      context.read<NotificationHistoryProvider>().markPayloadRead(data),
    );
    final kind = data['notification_kind']?.toString() ?? 'report';
    if (kind == 'duplicate') {
      showDuplicateGroupDetailSheet(context, DuplicateGroup.fromJson(data));
    } else {
      showReportDetailSheet(context, Report.fromJson(data));
    }
  }

  bool _checkingPendingChanges = false;
  Future<void> _checkPendingChanges() async {
    if (_checkingPendingChanges || !mounted || !_gateAllows) return;
    _checkingPendingChanges = true;
    final epoch = context.read<ReportProvider>().datasetEpoch;
    bool current() =>
        mounted &&
        _gateAllows &&
        context.read<ReportProvider>().datasetEpoch == epoch;
    try {
      final claim = await PendingChangesStore.readPending();
      final changes = claim.items;
      if (changes.isEmpty || !current() || !mounted) return;
      // Client: 서버가 알린 변경은 이 기기가 쓰지 않은 실제 자료 변경이다 — 보이는 목록·통계가 다시 읽는다(SQ-P02).
      // Standalone 은 동기화 뒤 refreshAll 이 DB 쓰기 표시로 판정한다.
      final reports = context.read<ReportProvider>();
      if (reports.appMode == AppMode.server) reports.markDataChanged();
      final history = context.read<NotificationHistoryProvider>();
      // 읽음 판정은 변경 하나 단위다(SQ-B01). 판정·기록 추가·저장을 한 번에 끝낸 뒤에만 ack 한다(SQ-B02).
      // 알림 히스토리에 extraData 포함해서 저장 (신고 결과 탭에서 상세 조회 가능하도록)
      final unreadChanges = await history.recordPendingChanges(
        changes,
        preferredTabIndexIfUnread: 1,
      );
      if (!current()) return;
      if (unreadChanges.isEmpty) {
        await PendingChangesStore.acknowledge(claim);
        return;
      }

      // 알림 탭으로 이동
      setState(() => _selectedIndex = 4);

      // 변경 신고건 카드 뷰 표시
      await Future.delayed(const Duration(milliseconds: 200));
      if (!current()) return;
      _showChangesBottomSheet(unreadChanges);
      await PendingChangesStore.acknowledge(claim);
    } catch (_) {
      SyncEngine.emitLog('대기 변경을 전달하지 못했습니다. 자료를 보존해 다시 확인합니다.');
    } finally {
      _checkingPendingChanges = false;
    }
  }

  void _showChangesBottomSheet(List<Map<String, dynamic>> changes) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // 전체 높이까지 끌어올려도 상태 표시줄 아래에서 멈춘다(SQ-U07).
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, controller) {
          final newCount = changes
              .where(
                (r) =>
                    r['notification_kind'] != 'duplicate' &&
                    r['change_type'] == ChangeType.newReport,
              )
              .length;
          final confirmCount = changes
              .where(
                (r) =>
                    r['notification_kind'] != 'duplicate' &&
                    r['change_type'] == ChangeType.individualConfirm,
              )
              .length;
          final duplicateCount = changes
              .where((r) => r['notification_kind'] == 'duplicate')
              .length;
          final changedCount =
              changes.length - newCount - confirmCount - duplicateCount;
          return Column(
            children: [
              // 손잡이는 테마(showDragHandle)가 그린다(SQ-U07).
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.sync_alt,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '변경 결과 ${changes.length}건',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (newCount > 0)
                          _changeBadge('신규', newCount, changeNewColor),
                        if (changedCount > 0)
                          _changeBadge('처리변경', changedCount, changeStatusColor),
                        if (confirmCount > 0)
                          _changeBadge(
                            '개별 확인',
                            confirmCount,
                            changeConfirmColor,
                          ),
                        if (duplicateCount > 0)
                          _changeBadge(
                            '중복 변경',
                            duplicateCount,
                            changeDuplicateColor,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.all(12),
                  itemCount: changes.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final r = changes[i];
                    final isDuplicate =
                        (r['notification_kind']?.toString() ?? '') ==
                        'duplicate';
                    if (isDuplicate) {
                      final statusLabel =
                          r['status_label']?.toString() ?? '중복 신고 변경';
                      final title = r['title']?.toString() ?? '중복 신고 변경';
                      final body = r['body']?.toString() ?? '';
                      final memberCount = r['member_count']?.toString() ?? '';
                      final representativeReportNumber =
                          r['representative_report_number']?.toString() ?? '';

                      return InkWell(
                        borderRadius: BorderRadius.circular(SrRadius.lg),
                        onTap: () {
                          Navigator.pop(ctx);
                          showDuplicateGroupDetailSheet(
                            context,
                            DuplicateGroup.fromJson(r),
                          );
                        },
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.only(right: 6),
                                      child: StatusBadge(
                                        label: '중복 변경',
                                        color: changeDuplicateColor,
                                        fontSize: SrFontSize.caption,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 120,
                                      ),
                                      child: StatusBadge(
                                        label: statusLabel,
                                        color: changeDuplicateColor,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 16,
                                      color: context.sr.textDisabled,
                                    ),
                                  ],
                                ),
                                if (body.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    body,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.sr.textSecondary,
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    if (representativeReportNumber.isNotEmpty)
                                      Text(
                                        '대표 신고번호: $representativeReportNumber',
                                        style: TextStyle(
                                          fontSize: SrFontSize.caption,
                                          color: context.sr.textSecondary,
                                        ),
                                      ),
                                    if (memberCount.isNotEmpty)
                                      Text(
                                        '멤버 수: $memberCount건',
                                        style: TextStyle(
                                          fontSize: SrFontSize.caption,
                                          color: context.sr.textSecondary,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    final changeType = r['change_type']?.toString() ?? '변경';
                    final isNew = changeType == ChangeType.newReport;
                    final isConfirm =
                        changeType == ChangeType.individualConfirm;
                    final badgeColor = isNew
                        ? changeNewColor
                        : isConfirm
                        ? changeConfirmColor
                        : changeStatusColor;
                    final badgeLabel = isNew
                        ? '신규'
                        : isConfirm
                        ? '개별 확인'
                        : '처리변경';
                    final reportNo = r['신고번호']?.toString() ?? '';
                    final name = r['신고명']?.toString() ?? '신고';
                    final status = r['처리상태']?.toString() ?? '';
                    final agency = r['처리기관']?.toString() ?? '';
                    final fine = r['범칙금_과태료']?.toString() ?? '';

                    final statusColor = serverStatusColor(status);

                    // 과태료/범칙금/경고/미확인 결과 라벨용 색상
                    Color? fineColor;
                    if (fine == '미확인') {
                      fineColor = serverUnconfirmedColor;
                    } else if (fine.isNotEmpty) {
                      fineColor = serverFineColor(fine);
                    }

                    return InkWell(
                      borderRadius: BorderRadius.circular(SrRadius.lg),
                      onTap: () {
                        Navigator.pop(ctx);
                        showReportDetailSheet(context, Report.fromJson(r));
                      },
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: StatusBadge(
                                      label: badgeLabel,
                                      color: badgeColor,
                                      fontSize: SrFontSize.caption,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 110,
                                    ),
                                    child: StatusBadge(
                                      label: status.isEmpty ? '처리 중' : status,
                                      color: statusColor,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (fineColor != null) ...[
                                    const SizedBox(width: 4),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 90,
                                      ),
                                      // 금액 있는 과태료/범칙금은 라벨만, 외(경고/미확인)는 그대로
                                      child: StatusBadge(
                                        label: fine.split(':').first.trim(),
                                        color: fineColor,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.chevron_right,
                                    size: 16,
                                    color: context.sr.textDisabled,
                                  ),
                                ],
                              ),
                              if (reportNo.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.tag,
                                      size: 13,
                                      color: context.sr.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      reportNo,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: context.sr.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (agency.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.business,
                                      size: 13,
                                      color: context.sr.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      agency,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: context.sr.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (fine.isNotEmpty && fine != 'null') ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.receipt_long,
                                      size: 13,
                                      color: context.sr.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      fine,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: context.sr.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _changeBadge(String label, int count, Color color) {
    return StatusBadge(label: '$label $count건', color: color, fontSize: 12);
  }

  int _lastPendingChangesNonce = 0;

  Widget _buildScreen(int index) {
    final cached = _screenCache[index];
    if (cached != null) return cached;
    final screen = switch (index) {
      0 => const DashboardScreen(),
      1 => const ReportListScreen(),
      2 => const ReportManagementScreen(),
      3 => const StatisticsScreen(),
      4 => const NotificationsScreen(),
      _ => const SizedBox.shrink(),
    };
    _screenCache[index] = screen;
    return screen;
  }

  @override
  Widget build(BuildContext context) {
    // 탭 화면은 캐시된 위젯이라 여기서 다시 그릴 필요가 있는 값만 구독한다(SQ-P07).
    context.select<ReportProvider, Object>(
      (p) => (
        p.appMode,
        p.isConfigured,
        p.isStandaloneDemo,
        p.pendingChangesNonce,
      ),
    );
    final p = context.read<ReportProvider>();
    // 하단 배지는 읽지 않은 수가 바뀔 때만 다시 그린다(SQ-P08).
    final unread = context.select<NotificationHistoryProvider, int>(
      (h) => h.unreadCount,
    );
    _refreshNativeQuickActionsIfNeeded(p);

    // standalone drain 이 변경을 기록하면 카드 시트 표시 (Client 모드 _checkPendingChanges 와 동일 흐름)
    if (p.pendingChangesNonce != _lastPendingChangesNonce) {
      _lastPendingChangesNonce = p.pendingChangesNonce;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkPendingChanges();
      });
    }

    final screen = Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: List<Widget>.generate(_tabCount, (index) {
          final cached = _screenCache[index];
          if (cached != null || index == _selectedIndex) {
            // 숨은 탭은 TickerMode false — 애니메이션 정지 + SelectionBackScope 가 뒤로가기를 가로채지 않게 한다.
            return TickerMode(
              enabled: index == _selectedIndex,
              child: _buildScreen(index),
            );
          }
          return const SizedBox.shrink();
        }),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 업데이트 뒤 한 번 훑기 진행(작업이 없으면 높이 0). Client 는 서버 작업, Standalone 은 이 기기 작업.
          if (p.isConfigured && !p.isStandaloneDemo)
            MaintenanceStatusBar(
              key: ValueKey('maintenance-${p.appMode.name}'),
              fetchServerStatus: p.appMode == AppMode.server
                  ? p.fetchMaintenanceStatus
                  : null,
            ),
          _buildNavigationBar(unread),
        ],
      ),
    );
    // 뒤로 가기: 선택 취소 → 비0 탭이면 대시보드 → 동기화 중 종료 막기 → 종료(SQ-U05).
    return MainTabScope(
      controller: _tabs,
      child: MainTabBackScope(
        currentIndex: _selectedIndex,
        onReturnHome: () => _selectTab(MainTabs.dashboard),
        child: screen,
      ),
    );
  }

  Widget _buildNavigationBar(int unread) {
    return NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: _selectTab,
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.dashboard_outlined),
          selectedIcon: Icon(Icons.dashboard),
          label: '대시보드',
        ),
        const NavigationDestination(
          icon: Icon(Icons.list_alt_outlined),
          selectedIcon: Icon(Icons.list_alt),
          label: '신고내역',
        ),
        const NavigationDestination(
          icon: Icon(Icons.inventory_2_outlined),
          selectedIcon: Icon(Icons.inventory_2),
          label: '신고관리',
        ),
        const NavigationDestination(
          icon: Icon(Icons.bar_chart_outlined),
          selectedIcon: Icon(Icons.bar_chart),
          label: '통계',
        ),
        NavigationDestination(
          icon: Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            child: const Icon(Icons.notifications_outlined),
          ),
          selectedIcon: Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            child: const Icon(Icons.notifications),
          ),
          label: '알림',
        ),
      ],
    );
  }

  void _refreshNativeQuickActionsIfNeeded(ReportProvider provider) {
    final signature = [
      provider.appMode.name,
      provider.isConfigured ? 'configured' : 'not-configured',
      provider.isStandaloneDemo ? 'demo' : 'live',
    ].join('|');
    if (signature == _lastQuickActionSignature) return;
    _lastQuickActionSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshNativeQuickActions());
    });
  }

  Future<void> _refreshNativeQuickActions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await NativeCallRouter.channel.invokeMethod('refreshQuickActions');
    } catch (_) {}
  }
}
