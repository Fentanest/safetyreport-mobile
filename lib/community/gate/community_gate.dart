import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/community_auth_config.dart';
import '../../services/community_auth_service.dart';
import '../../services/local_db_service.dart';
import '../capture/server_completed.dart' show deletionState;
import '../community_store.dart';
import '../upload_hooks.dart';
import 'community_account_client.dart';
import 'gate_state.dart';

export 'gate_state.dart';

/// writer 연결 충돌 (`connections` 409 `writer_conflict`).
class WriterConflict {
  final String deviceLabel;
  final String platform;
  final String sourceApp;
  final String createdAt;
  const WriterConflict({
    required this.deviceLabel,
    required this.platform,
    required this.sourceApp,
    required this.createdAt,
  });
}

/// 필수 진입 게이트 (`contracts/community-ingest/gate.md`).
///
/// - 판정 순서는 [evaluateGate] 그대로. 캐시 10분, `requireFresh(60s)`, `invalidate(reason)`.
/// - 60초 주기 poll 은 포그라운드에서만 (`WidgetsBindingObserver.resumed` 에서 즉시 refresh).
/// - Standalone 이고 status active 면 `CommunityStore.setContext(...)`, 게이트 상실이면 `deactivateContext`.
/// - writer 연결(Standalone 만): 등록·rebind·takeover 직후 T6 `refreshServerCompleted()` 호출.
/// - 네트워크 없이 동작하도록 전부 주입 가능하다.
class CommunityGate extends ChangeNotifier with WidgetsBindingObserver {
  CommunityGate({
    CommunityAuthConfig? config,
    CommunityAuthService? auth,
    CommunityStore? store,
    FlutterSecureStorage? secureStorage,
    http.Client? httpClient,
    CommunityAccountClient? accountClient,
    String Function()? configStatus,
    String Function()? appMode,
    Future<String?> Function()? officialAccountId,
    String Function()? deviceLabel,
    String Function()? platformName,
    String Function()? projectNamespace,
    Future<String> Function(String? kakaoId)? checkDataOwner,
  })  : _config = config ?? CommunityAuthConfig.fromEnvironment,
        _authOverride = auth,
        _store = store,
        _secureStorage =
            secureStorage ?? const FlutterSecureStorage(),
        _httpClient = httpClient,
        _accountClientOverride = accountClient,
        _configStatusOverride = configStatus,
        _appModeOverride = appMode,
        _officialAccountId = officialAccountId,
        _deviceLabelOverride = deviceLabel,
        _platformNameOverride = platformName,
        _projectNamespaceOverride = projectNamespace,
        _checkDataOwnerOverride = checkDataOwner {
    WidgetsBinding.instance.addObserver(this);
    _authPhase = _auth.state.value.phase;
    _auth.state.addListener(_onAuthChanged);
  }

  late CommunityAccountPhase _authPhase;

  /// 카카오 로그인이 확정되면(다른 상태 → connected) 곧바로 다시 확인한다. 예전엔 60초 poll·앱 복귀 때까지 기다려,
  /// 이미 동의한 계정도 필수 설정 화면에 머물렀다(2026-09-27). 로그아웃·만료도 즉시 반영한다.
  bool _disposed = false;

  /// 폐기 뒤에 끝난 확인(로그인 상태 변화로 시작된 refresh 등)은 조용히 멈춘다.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _onAuthChanged() {
    if (_disposed) return;
    final phase = _auth.state.value.phase;
    final was = _authPhase;
    _authPhase = phase;
    if (phase == was) return;
    // 로그인 진행 중 단계(브라우저 대기·교환·계정 확인)는 기존 세션이 그대로라 건드리지 않는다(설정의 "계정 변경" 중 튕기지 않게).
    final settled = phase == CommunityAccountPhase.connected ||
        phase == CommunityAccountPhase.disconnected ||
        phase == CommunityAccountPhase.reauthRequired;
    if (!settled) return;
    invalidate(phase == CommunityAccountPhase.connected ? 'login' : 'logout');
    unawaited(refreshNow(silent: true));
  }

  static const String connectionStorageKey = 'community_connection_v1';

  final CommunityAuthConfig _config;
  final CommunityAuthService? _authOverride;
  final CommunityStore? _store;
  final FlutterSecureStorage _secureStorage;
  final http.Client? _httpClient;
  final CommunityAccountClient? _accountClientOverride;
  final String Function()? _configStatusOverride;
  final String Function()? _appModeOverride;
  final Future<String?> Function()? _officialAccountId;
  final String Function()? _deviceLabelOverride;
  final String Function()? _platformNameOverride;
  final String Function()? _projectNamespaceOverride;
  final Future<String> Function(String? kakaoId)? _checkDataOwnerOverride;

  CommunityAuthService get _auth => _authOverride ?? CommunityAuthService.instance;

  GateState _state = const GateState(state: 'verification_required', canEnter: false);
  GateState get state => _state;

  /// 통과는 그때의 실행 모드에만 유효하다. Client·데모에서 통과한 뒤 실제 Standalone 으로 바꾸면 그 기기 DB 의 주인을
  /// 확인하지 않았으므로 다시 확인할 때까지 들어가지 않는다([onAppModeChanged]).
  bool get canEnter => _state.canEnter && _passedMode == appMode;
  String? _passedMode;

  /// 초기 검사가 끝났는가. 검사 중에는 로딩 셸만 보인다(기존 신고 화면 flash 금지).
  bool _checked = false;
  bool get isChecked => _checked;

  bool _checking = false;
  bool get isChecking => _checking;

  CommunityAccountStatus? _lastStatus;
  CommunityAccountStatus? get lastStatus => _lastStatus;
  DateTime? _verifiedAt;
  bool _invalidated = true;

  String? _notice;
  String? get notice => _notice;

  WriterConflict? _writerConflict;
  WriterConflict? get writerConflict => _writerConflict;

  String? _manifestError;
  String? get manifestError => _manifestError;

  Timer? _pollTimer;
  Future<GateState>? _inFlight;
  bool _firstPassFired = false;
  final List<FutureOr<void> Function()> _onFirstPassed = [];

  /// 게이트가 ok 로 처음 바뀔 때 1회 실행 (`ReportProvider.onGatePassed` 연결).
  void addOnFirstPassed(FutureOr<void> Function() cb) => _onFirstPassed.add(cb);

  /// 'standalone' | 'server'(Client) | 'demo'(Standalone 데모 — 화면은 Standalone 이지만 writer 가 아니다).
  String get appMode => _appModeOverride?.call() ?? 'standalone';
  bool get isStandalone => appMode != 'server';

  /// 이 기기가 공유 writer 인가. 데모·Client 는 연결 등록·업로드를 하지 않는다.
  bool get isWriter => appMode == 'standalone';

  String configStatus() {
    final override = _configStatusOverride?.call();
    if (override != null) return override;
    if (_config.isConfigured) return 'ok';
    final problem = _config.problem ?? '';
    if (problem.contains('비밀') || problem.contains('service_role')) {
      return 'secret_detected';
    }
    return 'missing';
  }

  String sessionStatus() {
    switch (_auth.state.value.phase) {
      case CommunityAccountPhase.disconnected:
      case CommunityAccountPhase.unconfigured:
        return 'none';
      case CommunityAccountPhase.reauthRequired:
        return 'reauth_required';
      case CommunityAccountPhase.connected:
      case CommunityAccountPhase.awaitingBrowser:
      case CommunityAccountPhase.exchanging:
      case CommunityAccountPhase.confirmRequired:
        return 'valid';
    }
  }

  /// 동의 저장·철회·연결 전환 화면이 쓰는 커뮤니티 계정 API 클라이언트(게이트와 같은 설정·주입값).
  CommunityAccountClient get accountClient => _client();

  CommunityAccountClient _client() {
    final override = _accountClientOverride;
    if (override != null) return override;
    return CommunityAccountClient(
      supabaseUrl: _config.supabaseUrl,
      publishableKey: _config.publishableKey,
      client: _httpClient,
    );
  }

  void startPolling() {
    _pollTimer ??= Timer.periodic(const Duration(seconds: 60), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(refreshNow(silent: true));
      }
    });
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshNow(silent: true));
    }
  }

  /// 로컬 철회·로그아웃·401/403 수신 뒤 status 를 다시 받기 전까지 진입 불가.
  void invalidate(String reason) {
    _invalidated = true;
    _passedMode = null;
    _apply(evaluateGate(
      config: configStatus(),
      session: sessionStatus(),
      status: _lastStatus?.toGateInput(),
      ageSeconds: _ageSeconds(),
      invalidated: true,
    ));
    unawaited(_deactivate(reason));
  }

  /// 실행 모드(Standalone·데모·Client)가 바뀌었을 수 있을 때(`ReportProvider` 변경 알림). 바뀌었으면 검사 중 화면을 보이고 다시 확인한다.
  void onAppModeChanged() {
    final passed = _passedMode;
    if (passed == null || passed == appMode) return;
    _checked = false;
    invalidate('mode_change');
    notifyListeners();
    unawaited(refreshNow());
  }

  Future<GateState> requireFresh({Duration maxAge = communityGateFreshMaxAge}) async {
    final age = _ageSeconds();
    if (_passedMode == appMode && !_invalidated && _lastStatus != null && age != null && age <= maxAge.inSeconds) {
      return _state;
    }
    return refreshNow();
  }

  double? _ageSeconds() {
    final v = _verifiedAt;
    if (v == null) return null;
    return DateTime.now().difference(v).inMilliseconds / 1000.0;
  }

  Future<GateState> refreshNow({bool silent = false}) {
    return _inFlight ??= _refresh(silent: silent).whenComplete(() => _inFlight = null);
  }

  Future<GateState> _refresh({bool silent = false}) async {
    if (!silent) {
      _checking = true;
      notifyListeners();
    }
    try {
      final config = configStatus();
      final session = sessionStatus();
      if (config != 'ok' || session != 'valid') {
        final next = evaluateGate(config: config, session: session);
        _apply(next);
        await _deactivate('gate:$next');
        _checked = true;
        notifyListeners();
        return _state;
      }
      final token = await _auth.getAccessToken();
      if (token == null || token.isEmpty) {
        final st = _auth.state.value.phase;
        final next = evaluateGate(
          config: config,
          session: st == CommunityAccountPhase.reauthRequired ? 'reauth_required' : 'none',
        );
        _apply(next);
        await _deactivate('gate:$next');
        _checked = true;
        notifyListeners();
        return _state;
      }
      final storedConnection = await _readStoredConnection();
      late final CommunityAccountStatus status;
      try {
        status = await _client().status(
          accessToken: token,
          connectionId: storedConnection?['connection_id'] as String?,
        );
      } on CommunityAccountError catch (e) {
        if (e.isAuth) {
          invalidate('auth:${e.code}');
        } else {
          _notice = e.message;
          final age = _ageSeconds();
          if (_lastStatus != null && !_invalidated && age != null && age <= communityGateCacheTtl.inSeconds) {
            _checked = true;
            notifyListeners();
            return _state;
          }
          _apply(evaluateGate(config: config, session: session));
        }
        _checked = true;
        notifyListeners();
        return _state;
      }
      _lastStatus = status;
      _verifiedAt = DateTime.now();
      _invalidated = false;
      _notice = null;
      final next = evaluateGate(
        config: config,
        session: session,
        status: status.toGateInput(),
        ageSeconds: 0,
      );
      if (!next.canEnter) {
        _apply(next);
        await _deactivate('gate:${next.state}');
        _checked = true;
        notifyListeners();
        return _state;
      }
      if (isWriter) {
        // 카카오 로그인·동의가 끝나도, 이 기기의 신고 자료가 다른 카카오 계정 것이면 들어가지 않는다(자료를 지우거나 로그아웃할 때까지).
        // 다른 계정의 자료가 남아 있으면 writer 연결도 만들지 않는다(PC services/community_gate.py _check_owner 와 같은 규칙).
        final owner = await _checkOwner();
        if (owner != 'ok') {
          final blocked = owner == 'mismatch'
              ? const GateState(state: 'db_owner_mismatch', canEnter: false, reasons: ['db_owner_mismatch'])
              : GateState(
                  state: 'verification_required',
                  canEnter: false,
                  reasons: ['data_owner_unverified', ?_ownerError],
                );
          _apply(blocked);
          await _deactivate('gate:${blocked.state}');
          _checked = true;
          notifyListeners();
          return _state;
        }
        // 진입(K·C)과 업로드 연결은 별개다: 연결을 못 얻으면 화면은 쓰되 context 를 끄고 업로드만 멈춘다.
        final blocked = await _ensureWriterConnection(status, token);
        if (blocked == null) {
          await _activateContext(status);
        } else {
          await _deactivate('writer:$blocked');
        }
      } else {
        // Client: 폰은 writer 가 아니다(업로드·자정 없음). 서버가 자기 게이트로 올린다. 데모도 writer 가 아니다.
        await _deactivate(appMode == 'demo' ? 'demo_mode' : 'client_mode');
      }
      _apply(next);
      _passedMode = appMode;
      _checked = true;
      final store = _store;
      if (store != null && await deletionState(store: store) == 'unconfirmed') {
        _notice = '공유한 자료 삭제 요청의 결과를 확인하지 못해 업로드를 멈춘 상태입니다. 설정에서 삭제 요청을 다시 눌러 주세요.';
      }
      notifyListeners();
      if (!_firstPassFired) {
        _firstPassFired = true;
        for (final cb in _onFirstPassed) {
          try {
            await cb();
          } catch (_) {}
        }
      }
      return _state;
    } finally {
      if (!silent) {
        _checking = false;
        notifyListeners();
      }
    }
  }

  String? _ownerError;

  /// 게이트 통과 뒤(Standalone writer): 개인 DB 의 주인 카카오 회원번호를 확인(처음이면 적음). 번호를 못 받으면 'unknown'.
  Future<String> _checkOwner() async {
    _ownerError = null;
    String? kakaoId;
    try {
      kakaoId = await _auth.currentKakaoId();
    } on CommunityKakaoIdUnavailable catch (e) {
      _ownerError = e.code;
    } catch (_) {
      _ownerError = 'auth_unavailable';
    }
    try {
      return await (_checkDataOwnerOverride ?? LocalDbService.checkOwner)(kakaoId);
    } catch (_) {
      return 'unknown';
    }
  }

  /// 백그라운드 업로드(Workmanager)가 읽는 게이트 캐시(`isGateCacheFresh`, T6). ok 가 아니면 즉시 막힌다.
  static const String gateCacheKey = 'community_gate_cache_v1';

  void _apply(GateState next) {
    _state = next;
    unawaited(_writeGateCache(next));
  }

  Future<void> _writeGateCache(GateState next) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(gateCacheKey, jsonEncode({
        'state': next.state,
        'verified_at': (next.canEnter ? (_verifiedAt ?? DateTime.now()) : DateTime.now()).millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  Future<void> _deactivate(String reason) async {
    if (!reason.startsWith('writer:')) _writerConflict = null;
    try {
      await _store?.deactivateContext(reason);
    } catch (_) {}
  }

  Future<void> _activateContext(CommunityAccountStatus status) async {
    final store = _store;
    if (store == null) return;
    final stored = await _readStoredConnection();
    try {
      await store.setContext({
        'contributor_fingerprint': status.fingerprint,
        'connection_id': stored?['connection_id'],
        'writer_epoch': stored?['writer_epoch'],
        'dataset_key': stored?['dataset_key'],
        'consent_grant_id': status.consentGrantId,
        'policy_version': status.consentPolicyVersion,
        'consent_text_sha256': status.grantConsentTextSha256,
        'source_app': 'safetyreport-mobile',
        'source_mode': isStandalone ? 'standalone' : 'client',
      });
    } catch (_) {}
  }

  /// Standalone writer 연결 확보. null = 연결 정상(context 활성화), 문자열 = 업로드를 멈출 이유(context 비활성).
  /// PC `community_gate._ensure_writer` 와 같은 규칙: 같은 사용자·같은 공식 계정의 저장 연결이 status 에서 active 면
  /// (현재 세션에 묶이지 않았을 때만) rebind, superseded·suspended 면 멈춤(사용자가 전환 선택), 없거나 폐기면 새로 등록.
  Future<String?> _ensureWriterConnection(CommunityAccountStatus status, String token) async {
    _writerConflict = null;
    _manifestError = null;
    final officialId = await _officialAccountId?.call();
    if (officialId == null || officialId.trim().isEmpty) {
      return 'official_account_required';
    }
    final datasetKey = datasetKeyForOfficialId(officialId);
    final stored = await _readStoredConnection();
    // status 는 저장 연결 id 로 요청했고, 그 연결이 이 사용자 것일 때만 connection 을 채운다(계약).
    final conn = (stored != null && stored['dataset_key'] == datasetKey) ? status.connection : null;
    int? lastAccepted;
    try {
      if (conn != null && conn['status'] == 'active') {
        lastAccepted = (conn['last_accepted_revision'] as num?)?.toInt();
        if (conn['bound_to_current_session'] != true) {
          final rebound = await _client().rebindConnection(
            accessToken: token,
            connectionId: (stored!['connection_id'] ?? '') as String,
            connectionSecret: (stored['connection_secret'] ?? '') as String,
          );
          lastAccepted = rebound.lastAcceptedRevision ?? lastAccepted;
          await _writeStoredConnection(
            connectionId: rebound.connectionId,
            connectionSecret: (stored['connection_secret'] ?? '') as String,
            datasetKey: datasetKey,
            writerEpoch: rebound.writerEpoch,
          );
        }
      } else if (conn != null && (conn['status'] == 'superseded' || conn['status'] == 'suspended')) {
        return 'connection_${conn['status']}';
      } else {
        // 저장 연결 없음·다른 공식 계정·다른 사용자(status 가 null 로 숨김)·폐기됨 → 새 등록
        final registered = await _registerFresh(token, datasetKey, takeover: false);
        if (registered == null) return 'writer_conflict';
      }
    } on CommunityAccountError catch (e) {
      _notice = e.message;
      return e.code;
    }
    if (lastAccepted != null && lastAccepted > 0) {
      try {
        await _store?.raiseRevisionFloor(lastAccepted);
      } catch (_) {}
    }
    final manifestOk = await CommunityUploadHooks.refreshServerCompletedNow();
    if (!manifestOk) {
      // 수집 시작 전 scope 검사(SyncEngine.ensureManifestFresh)가 다시 시도하고, 실패하면 수집하지 않는다.
      _manifestError = '중앙 공유 목록을 확인하지 못했습니다. 다시 시도해 주세요.';
    }
    return null;
  }

  /// 새 연결 등록. `writer_conflict` 면 [_writerConflict] 를 세우고 null 반환.
  Future<CommunityConnectionResult?> _registerFresh(
    String token,
    String datasetKey, {
    required bool takeover,
  }) async {
    try {
      final secret = _newConnectionSecret();
      final result = await _client().registerConnection(
        accessToken: token,
        sourceMode: isStandalone ? 'standalone' : 'client',
        platform: _platformNameOverride?.call() ?? defaultTargetPlatform.name,
        deviceLabel: _deviceLabelOverride?.call() ?? 'mobile',
        datasetKey: datasetKey,
        connectionSecret: secret,
        takeover: takeover,
      );
      await _writeStoredConnection(
        connectionId: result.connectionId,
        connectionSecret: secret,
        datasetKey: datasetKey,
        writerEpoch: result.writerEpoch,
      );
      return result;
    } on CommunityAccountError catch (e) {
      if (e.code == 'writer_conflict' && !takeover) {
        final w = (e.extra['active_writer'] as Map?)?.cast<String, Object?>() ?? const {};
        _writerConflict = WriterConflict(
          deviceLabel: (w['device_label'] as String?) ?? '',
          platform: (w['platform'] as String?) ?? '',
          sourceApp: (w['source_app'] as String?) ?? '',
          createdAt: (w['created_at'] as String?) ?? '',
        );
        return null;
      }
      rethrow;
    }
  }

  /// "이 기기로 업로드 전환" — takeover 등록.
  Future<bool> requestTakeover() async {
    final token = await _auth.getAccessToken();
    final officialId = await _officialAccountId?.call();
    if (token == null || officialId == null || officialId.trim().isEmpty) {
      return false;
    }
    try {
      await _registerFresh(token, datasetKeyForOfficialId(officialId), takeover: true);
    } on CommunityAccountError catch (e) {
      _notice = e.message;
      notifyListeners();
      return false;
    }
    _writerConflict = null;
    await refreshNow();
    return true;
  }

  /// 연결 비밀: 암호학적 난수 32바이트(base64url). 이전 구현은 시각 해시라 추측 가능했다(통합 검수에서 수정).
  String _newConnectionSecret() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<Map<String, Object?>?> _readStoredConnection() async {
    try {
      final raw = await _secureStorage.read(key: connectionStorageKey);
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      return json.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeStoredConnection({
    required String connectionId,
    required String connectionSecret,
    required String datasetKey,
    required int writerEpoch,
  }) async {
    final ns = _projectNamespaceOverride?.call() ?? projectNamespace(_config.supabaseUrl);
    await _secureStorage.write(
      key: connectionStorageKey,
      value: jsonEncode({
        'v': 1,
        'connection_id': connectionId,
        'connection_secret': connectionSecret,
        'dataset_key': datasetKey,
        'project_namespace': ns,
        'writer_epoch': writerEpoch,
      }),
    );
  }

  Future<void> _clearStoredConnection() async {
    try {
      await _secureStorage.delete(key: connectionStorageKey);
    } catch (_) {}
  }

  /// 공유 자료 삭제 성공 뒤: T6 대기 행 차단 + 저장 연결 폐기 + 다음 통과 때 재등록.
  /// 로컬 정리가 끝나 남은 삭제 표시가 없으면 true. 아니면 notice 를 남기고 false(업로드는 표시로 계속 막힘).
  Future<bool> handleContributionsDeleted() async {
    // 적용은 이미 한 번 시도됐을 수 있다(requestDeletion) — 표시가 없으면 아무 일도 하지 않으므로 다시 불러도 안전하다.
    final ok = await CommunityUploadHooks.contributionsDeletedNow();
    if (!ok) {
      _notice = '중앙에서는 삭제했지만 이 기기의 대기 사본 정리를 끝내지 못했습니다. 정리될 때까지 업로드하지 않습니다. '
          '설정에서 삭제 요청을 다시 눌러 주세요.';
    }
    await _clearStoredConnection();
    invalidate('contributions_deleted');
    return ok;
  }

  @override
  void dispose() {
    _disposed = true;
    stopPolling();
    _auth.state.removeListener(_onAuthChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
