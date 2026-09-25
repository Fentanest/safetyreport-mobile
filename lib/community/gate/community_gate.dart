import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../services/community_auth_config.dart';
import '../../services/community_auth_service.dart';
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
        _projectNamespaceOverride = projectNamespace {
    WidgetsBinding.instance.addObserver(this);
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

  CommunityAuthService get _auth => _authOverride ?? CommunityAuthService.instance;

  GateState _state = const GateState(state: 'verification_required', canEnter: false);
  GateState get state => _state;
  bool get canEnter => _state.canEnter;

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

  String get appMode => _appModeOverride?.call() ?? 'standalone';
  bool get isStandalone => appMode != 'server';

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
    _apply(evaluateGate(
      config: configStatus(),
      session: sessionStatus(),
      status: _lastStatus?.toGateInput(),
      ageSeconds: _ageSeconds(),
      invalidated: true,
    ));
    unawaited(_deactivate(reason));
  }

  Future<GateState> requireFresh({Duration maxAge = communityGateFreshMaxAge}) async {
    final age = _ageSeconds();
    if (!_invalidated && _lastStatus != null && age != null && age <= maxAge.inSeconds) {
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
        appRequiredPolicyVersion: communityRequiredPolicyVersion,
      );
      if (!next.canEnter) {
        _apply(next);
        await _deactivate('gate:${next.state}');
        _checked = true;
        notifyListeners();
        return _state;
      }
      if (isStandalone) {
        final ok = await _ensureWriterConnection(status, token);
        if (!ok) {
          _checked = true;
          notifyListeners();
          return _state;
        }
        await _activateContext(status);
      } else {
        await _activateContext(status);
      }
      _apply(next);
      _checked = true;
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

  void _apply(GateState next) {
    _state = next;
  }

  Future<void> _deactivate(String reason) async {
    _writerConflict = null;
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
        'consent_text_sha256': status.consentTextSha256,
        'source_app': 'safetyreport-mobile',
        'source_mode': isStandalone ? 'standalone' : 'client',
      });
    } catch (_) {}
  }

  /// Standalone writer 연결 보장. false 면 게이트 통과로 보지 않고 재시도 안내만 둔다.
  Future<bool> _ensureWriterConnection(CommunityAccountStatus status, String token) async {
    _writerConflict = null;
    _manifestError = null;
    final officialId = await _officialAccountId?.call();
    if (officialId == null || officialId.trim().isEmpty) {
      return true;
    }
    final datasetKey = datasetKeyForOfficialId(officialId);
    final stored = await _readStoredConnection();
    try {
      if (stored != null && stored['dataset_key'] == datasetKey) {
        final rebound = await _client().rebindConnection(
          accessToken: token,
          connectionId: (stored['connection_id'] ?? '') as String,
          connectionSecret: (stored['connection_secret'] ?? '') as String,
        );
        await _writeStoredConnection(
          connectionId: rebound.connectionId,
          connectionSecret: (stored['connection_secret'] ?? '') as String,
          datasetKey: datasetKey,
          writerEpoch: rebound.writerEpoch,
        );
      } else {
        final registered = await _registerFresh(token, datasetKey, takeover: false);
        if (registered == null) return true;
      }
    } on CommunityAccountError catch (e) {
      if (e.code == 'writer_conflict') {
        _writerConflict = const WriterConflict(
          deviceLabel: '',
          platform: '',
          sourceApp: '',
          createdAt: '',
        );
        _apply(evaluateGate(config: 'ok', session: 'valid'));
        return true;
      }
      if (e.code == 'not_found') {
        await _clearStoredConnection();
        final registered = await _registerFresh(token, datasetKey, takeover: false);
        if (registered == null) return true;
      } else {
        _notice = e.message;
        return true;
      }
    }
    final manifestOk = await CommunityUploadHooks.refreshServerCompletedNow();
    if (!manifestOk) {
      _manifestError = '중앙 공유 목록을 확인하지 못했습니다. 다시 시도해 주세요.';
    }
    return true;
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
        _writerConflict = const WriterConflict(
          deviceLabel: '',
          platform: '',
          sourceApp: '',
          createdAt: '',
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

  String _newConnectionSecret() {
    final rand = DateTime.now().microsecondsSinceEpoch.toString();
    final bytes = sha256.convert(utf8.encode('connection|$rand')).bytes;
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
  Future<void> handleContributionsDeleted() async {
    await CommunityUploadHooks.contributionsDeletedNow();
    await _clearStoredConnection();
    invalidate('contributions_deleted');
  }

  @override
  void dispose() {
    stopPolling();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
