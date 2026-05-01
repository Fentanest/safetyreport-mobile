import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_mode.dart';
import '../models/report.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/permission_service.dart';
import '../services/standalone_auth_service.dart';
import '../services/standalone_auto_sync_service.dart';
import '../services/sync_engine.dart';

const _defaultStatusOrder = <String>[
  '수용', '일부수용', '불수용', '처리중', '진행', '진행중', '취하', '기타', '답변완료',
];

class ReportFilter {
  final String name;
  final String reportNumber;
  final List<String> ratings;
  final String ratingCause;
  final String agency;
  final String manager;
  final String carNumber;
  final String law;
  final String location;
  final String fine;
  final String reportContent;
  final String processContent;
  final List<String> statuses;
  final String reportDateStart;
  final String reportDateEnd;
  final String occurDateStart;
  final String occurDateEnd;
  final String responseDateStart;
  final String responseDateEnd;
  final String occurTimeStart;
  final String occurTimeEnd;
  final bool excludePolice;
  final bool onlyPolice;

  const ReportFilter({
    this.name = '',
    this.reportNumber = '',
    this.ratings = const [],
    this.ratingCause = '',
    this.agency = '',
    this.manager = '',
    this.carNumber = '',
    this.law = '',
    this.location = '',
    this.fine = '',
    this.reportContent = '',
    this.processContent = '',
    this.statuses = const [],
    this.reportDateStart = '',
    this.reportDateEnd = '',
    this.occurDateStart = '',
    this.occurDateEnd = '',
    this.responseDateStart = '',
    this.responseDateEnd = '',
    this.occurTimeStart = '',
    this.occurTimeEnd = '',
    this.excludePolice = false,
    this.onlyPolice = false,
  });

  bool get isEmpty =>
      name.isEmpty &&
      reportNumber.isEmpty &&
      ratings.isEmpty &&
      ratingCause.isEmpty &&
      agency.isEmpty &&
      manager.isEmpty &&
      carNumber.isEmpty &&
      law.isEmpty &&
      location.isEmpty &&
      fine.isEmpty &&
      reportContent.isEmpty &&
      processContent.isEmpty &&
      statuses.isEmpty &&
      reportDateStart.isEmpty &&
      reportDateEnd.isEmpty &&
      occurDateStart.isEmpty &&
      occurDateEnd.isEmpty &&
      responseDateStart.isEmpty &&
      responseDateEnd.isEmpty &&
      occurTimeStart.isEmpty &&
      occurTimeEnd.isEmpty &&
      !excludePolice &&
      !onlyPolice;

  /// 활성 필터 항목 요약 (Chip 표시용)
  List<String> get activeLabels {
    final list = <String>[];
    if (name.isNotEmpty) list.add('신고명: $name');
    if (reportNumber.isNotEmpty) list.add('신고번호: $reportNumber');
    if (ratings.isNotEmpty) {
      list.add('별점: ${ratings.map((rating) => rating == '__none__' ? '없음' : '$rating점').join(', ')}');
    }
    if (ratingCause.isNotEmpty) list.add('별점사유: $ratingCause');
    if (agency.isNotEmpty) list.add('기관: $agency');
    if (manager.isNotEmpty) list.add('담당자: $manager');
    if (carNumber.isNotEmpty) list.add('차량: $carNumber');
    if (law.isNotEmpty) list.add('위반법규: $law');
    if (location.isNotEmpty) list.add('위반장소: $location');
    if (fine.isNotEmpty) list.add('과태료: $fine');
    if (reportContent.isNotEmpty) list.add('신고내용: $reportContent');
    if (processContent.isNotEmpty) list.add('처리내용: $processContent');
    if (statuses.isNotEmpty) list.add('상태: ${statuses.join(', ')}');
    if (reportDateStart.isNotEmpty || reportDateEnd.isNotEmpty) {
      list.add('신고일: $reportDateStart~$reportDateEnd');
    }
    if (occurDateStart.isNotEmpty || occurDateEnd.isNotEmpty) {
      list.add('발생일: $occurDateStart~$occurDateEnd');
    }
    if (responseDateStart.isNotEmpty || responseDateEnd.isNotEmpty) {
      list.add('답변일: $responseDateStart~$responseDateEnd');
    }
    if (occurTimeStart.isNotEmpty || occurTimeEnd.isNotEmpty) {
      list.add('발생시각: $occurTimeStart~$occurTimeEnd');
    }
    if (excludePolice) list.add('경찰기관 제외');
    if (onlyPolice) list.add('경찰기관만');
    return list;
  }

  String get rating => ratings.join(',');
  String get status => statuses.join(',');
}

class ReportProvider with ChangeNotifier {
  AppMode _appMode = AppMode.server;
  String _standaloneUsername = '';
  String _standalonePhoneNumber = '';
  bool _isStandaloneDemo = false;
  String _baseUrl = '';
  String _apiKey = '';
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _errorMessage;
  DashboardStats? _stats;
  List<Report> _trafficReports = [];
  List<Report> _parkingReports = [];
  List<Report> _otherReports = [];
  List<Report> _duplicateReports = [];
  Set<String> _watchlistNumbers = {};

  ReportFilter _filter = const ReportFilter();
  bool _excludeWithdraw = false;
  bool _normalizePolice = false;

  // 탭 전환 시 내부 state 가 있는 화면(통계/파일)이 재로드하도록 바꾸는 nonce.
  // 화면들은 이 값을 watch 하다가 변경 시 refresh 를 수행.
  int _statsRefreshNonce = 0;
  int _filesRefreshNonce = 0;
  int get statsRefreshNonce => _statsRefreshNonce;
  int get filesRefreshNonce => _filesRefreshNonce;
  void bumpStatsRefresh() { _statsRefreshNonce++; notifyListeners(); }
  void bumpFilesRefresh() { _filesRefreshNonce++; notifyListeners(); }

  // SyncEngine.emitChanges 호출 시마다 증가. main.dart 가 watch 하다가
  // _checkPendingChanges() 재실행 → pending_crawl_changes 소비 + 카드 시트 표시.
  int _pendingChangesNonce = 0;
  int get pendingChangesNonce => _pendingChangesNonce;
  StreamSubscription<void>? _changesEmittedSub;

  AppMode get appMode => _appMode;
  String get standaloneUsername => _standaloneUsername;
  String get standalonePhoneNumber => _standalonePhoneNumber;
  bool get isStandaloneDemo => _isStandaloneDemo;
  String get baseUrl => _baseUrl;
  String get apiKey => _apiKey;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  bool get isConfigured {
    if (_appMode == AppMode.standalone) return _standaloneUsername.isNotEmpty;
    return _baseUrl.isNotEmpty && _apiKey.isNotEmpty;
  }
  String? get errorMessage => _errorMessage;
  DashboardStats? get stats => _stats;
  bool get excludeWithdraw => _excludeWithdraw;
  bool get normalizePolice => _normalizePolice;
  List<Report> get trafficReports => _trafficReports;
  List<Report> get parkingReports => _parkingReports;
  List<Report> get otherReports => _otherReports;
  List<Report> get duplicateReports => _duplicateReports;
  Set<String> get watchlistNumbers => _watchlistNumbers;
  bool isInWatchlist(String reportNumber) => _watchlistNumbers.contains(reportNumber);
  ReportFilter get filter => _filter;
  bool get isSyncing => _isSyncing;
  bool _isSyncing = false;
  void setSyncing(bool val) {
    if (_isSyncing == val) return;
    _isSyncing = val;
    notifyListeners();
  }

  bool get hasFilter => !_filter.isEmpty;

  List<Report> get filteredTrafficReports => _applyFilter(_trafficReports);
  List<Report> get filteredParkingReports => _applyFilter(_parkingReports);
  List<Report> get filteredOtherReports => _applyFilter(_otherReports);
  // 중복차량은 서버에서 이미 그룹/정렬되므로 필터 미적용
  List<Report> get filteredDuplicateReports => _duplicateReports;

  List<String> get availableStatuses {
    final seen = <String>{};
    final discovered = <String>[];

    void collect(Iterable<Report> reports) {
      for (final report in reports) {
        final status = report.status.trim();
        if (status.isEmpty || !seen.add(status)) continue;
        discovered.add(status);
      }
    }

    collect(_trafficReports);
    collect(_parkingReports);
    collect(_otherReports);
    for (final status in _filter.statuses) {
      final trimmed = status.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      discovered.add(trimmed);
    }

    final preferred = _defaultStatusOrder.where(seen.contains).toList();
    final extras = discovered.where((status) => !_defaultStatusOrder.contains(status)).toList()
      ..sort((a, b) => a.compareTo(b));
    return [...preferred, ...extras];
  }

  List<List<String>> _parseAndOrGroups(String query) {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final groups = <List<String>>[];
    for (final rawGroup in text.split(',')) {
      final terms = rawGroup
          .split('&')
          .map((term) => term.trim().toLowerCase())
          .where((term) => term.isNotEmpty)
          .toList();
      if (terms.isNotEmpty) groups.add(terms);
    }
    return groups;
  }

  bool _contains(String source, String query) =>
      query.trim().isEmpty ||
      _parseAndOrGroups(query).any((group) =>
          group.every((term) => source.toLowerCase().contains(term)));

  bool _dateGte(String value, String bound) =>
      bound.isEmpty || value.isEmpty || value.compareTo(bound) >= 0;

  bool _dateLte(String value, String bound) =>
      bound.isEmpty || value.isEmpty || value.compareTo(bound) <= 0;

  List<Report> _applyFilter(List<Report> reports) {
    final f = _filter;
    return reports.where((r) {
      if (!_contains(r.name, f.name)) return false;
      if (!_contains(r.reportNumber, f.reportNumber)) return false;
      if (f.ratings.isNotEmpty) {
        final ratingToken =
            (r.rating == null || r.rating! <= 0) ? '__none__' : r.rating.toString();
        if (!f.ratings.contains(ratingToken)) return false;
      }
      if (!_contains(r.ratingCause, f.ratingCause)) return false;
      if (!_contains(r.agency, f.agency)) return false;
      if (!_contains(r.manager, f.manager)) return false;
      if (!_contains(r.carNumber, f.carNumber)) return false;
      if (!_contains(r.law, f.law)) return false;
      if (!_contains(r.location, f.location)) return false;
      if (!_contains(r.fineInfo, f.fine)) return false;
      if (!_contains(r.reportContent, f.reportContent)) return false;
      if (!_contains(r.processContent, f.processContent)) return false;
      if (f.statuses.isNotEmpty && !f.statuses.contains(r.status.trim())) return false;
      if (!_dateGte(r.date, f.reportDateStart)) return false;
      if (!_dateLte(r.date, f.reportDateEnd)) return false;
      if (!_dateGte(r.occurrenceDate, f.occurDateStart)) return false;
      if (!_dateLte(r.occurrenceDate, f.occurDateEnd)) return false;
      if (!_dateGte(r.responseDate, f.responseDateStart)) return false;
      if (!_dateLte(r.responseDate, f.responseDateEnd)) return false;
      if (!_dateGte(r.occurrenceTime, f.occurTimeStart)) return false;
      if (!_dateLte(r.occurrenceTime, f.occurTimeEnd)) return false;
      if (f.excludePolice && r.agency.contains('경찰')) return false;
      if (f.onlyPolice && !r.agency.contains('경찰')) return false;
      return true;
    }).toList();
  }

  void setFilter(ReportFilter filter) {
    _filter = filter;
    notifyListeners();
  }

  void clearFilter() {
    _filter = const ReportFilter();
    notifyListeners();
  }

  Future<void> fetchAppConfig() async {
    if (!isConfigured) return;
    if (_appMode == AppMode.standalone) {
      final prefs = await SharedPreferences.getInstance();
      _excludeWithdraw = prefs.getBool('standaloneExcludeWithdraw') ?? true;
      _normalizePolice = prefs.getBool('standaloneNormalizePolice') ?? true;
      notifyListeners();
      return;
    }
    try {
      final cfg = await _api.getAppConfig();
      _excludeWithdraw = cfg['exclude_withdraw'] as bool? ?? false;
      _normalizePolice = cfg['normalize_police'] as bool? ?? false;
      notifyListeners();
    } catch (_) {}
  }

  /// standalone 전용 설정 토글 — SharedPreferences 영속화 + 데이터 재로드
  Future<void> setStandaloneFilter({bool? excludeWithdraw, bool? normalizePolice}) async {
    final prefs = await SharedPreferences.getInstance();
    if (excludeWithdraw != null) {
      _excludeWithdraw = excludeWithdraw;
      await prefs.setBool('standaloneExcludeWithdraw', excludeWithdraw);
    }
    if (normalizePolice != null) {
      _normalizePolice = normalizePolice;
      await prefs.setBool('standaloneNormalizePolice', normalizePolice);
    }
    notifyListeners();
    await refreshAll();
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(const Duration(seconds: 5));
      _appMode = AppModeX.fromString(prefs.getString('appMode'));
      _standaloneUsername = prefs.getString('standaloneUsername') ?? '';
      _standalonePhoneNumber = prefs.getString('standalonePhoneNumber') ?? '';
      _isStandaloneDemo = prefs.getBool('standaloneDemoMode') ?? false;
      _baseUrl = prefs.getString('baseUrl') ?? '';
      _apiKey = prefs.getString('apiKey') ?? '';
      
      _changesEmittedSub ??= SyncEngine.changesEmitted.listen((_) {
        _pendingChangesNonce++;
        notifyListeners();
      });

      if (isConfigured) {
        fetchWatchlistNumbers();
        fetchAppConfig();
        // standalone: 기존 DB 즉시 표시 후 pending 큐 처리
        if (_appMode == AppMode.standalone) {
          () async {
            if (!_isStandaloneDemo) {
              StandaloneAuthService.startKeepAlive();
            }
            // 먼저 현재 DB 데이터로 대시보드 즉시 구성 (drain 이 오래 걸려도 빈 화면 없음)
            await refreshAll();
            // 그 다음 pending 큐 처리 (네트워크 필요, 오래 걸릴 수 있음)
            if (!_isStandaloneDemo) {
              await _drainAndRefresh();
            }
          }();
        }
      }
    } catch (e) {
      _errorMessage = '초기화 실패: $e';
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _changesEmittedSub?.cancel();
    StandaloneAuthService.stopKeepAlive();
    super.dispose();
  }

  /// foreground 복귀 시 호출 (main.dart AppLifecycleState.resumed).
  Future<void> checkAutoSyncOnResume() async {
    if (_appMode != AppMode.standalone || !isConfigured) return;
    if (_isStandaloneDemo) {
      await refreshAll();
      return;
    }
    StandaloneAuthService.startKeepAlive();
    await StandaloneAuthService.refreshSessionIfNeeded();
    await _drainAndRefresh();
  }

  /// drain 트리거 + UI 갱신. init() 와 checkAutoSyncOnResume 공통.
  /// 큐가 비어있으면 drainIfPending 첫 iteration 에서 즉시 break 하므로 비용 거의 없음.
  Future<void> _drainAndRefresh() async {
    await StandaloneAutoSyncService.drainIfPending();
    if (_appMode == AppMode.standalone) await refreshAll();
  }

  Future<void> setConfig(String url, String key) async {
    StandaloneAuthService.stopKeepAlive();
    final cleanUrl =
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    _appMode = AppMode.server;
    _isStandaloneDemo = false;
    _baseUrl = cleanUrl;
    _apiKey = key;
    _errorMessage = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appMode', AppMode.server.name);
    await prefs.setString('baseUrl', _baseUrl);
    await prefs.setString('apiKey', _apiKey);
    await prefs.remove('standaloneDemoMode');

    notifyListeners();
  }

  Future<void> setStandaloneConfig(
    String username, {
    required String phoneNumber,
    bool isDemoMode = false,
  }) async {
    await PermissionService.stopWsService();
    if (isDemoMode) {
      StandaloneAuthService.stopKeepAlive();
      await StandaloneAuthService.clearToken();
    } else {
      StandaloneAuthService.startKeepAlive();
    }
    _appMode = AppMode.standalone;
    _standaloneUsername = username;
    _standalonePhoneNumber = isDemoMode
        ? phoneNumber.trim()
        : phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
    _isStandaloneDemo = isDemoMode;
    _errorMessage = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appMode', AppMode.standalone.name);
    await prefs.setString('standaloneUsername', username);
    await prefs.setString('standalonePhoneNumber', _standalonePhoneNumber);
    await prefs.setBool('standaloneDemoMode', isDemoMode);

    notifyListeners();
  }

  Future<void> resetConfig() async {
    await PermissionService.stopWsService();
    StandaloneAuthService.stopKeepAlive();
    _appMode = AppMode.server;
    _baseUrl = '';
    _apiKey = '';
    _standaloneUsername = '';
    _standalonePhoneNumber = '';
    _isStandaloneDemo = false;
    _stats = null;
    _trafficReports = [];
    _parkingReports = [];
    _otherReports = [];
    _duplicateReports = [];
    _watchlistNumbers = {};
    _errorMessage = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('appMode');
    await prefs.remove('baseUrl');
    await prefs.remove('apiKey');
    await prefs.remove('standaloneUsername');
    await prefs.remove('standalonePhoneNumber');
    await prefs.remove('standaloneDemoMode');
    await StandaloneAuthService.clearToken();

    notifyListeners();
  }

  ApiService get _api => ApiService(baseUrl: _baseUrl, apiKey: _apiKey);

  Future<void> fetchSummary() async {
    if (!isConfigured) return;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      if (_appMode == AppMode.standalone) {
        _stats = await LocalDbService.computeSummary(
          excludeWithdraw: _excludeWithdraw,
          normalizePolice: _normalizePolice,
        ).timeout(const Duration(seconds: 5), onTimeout: () {
          throw Exception('로컬 DB 응답 지연 (데드락 의심)');
        });
      } else {
        _stats = await _api.getSummary().timeout(const Duration(seconds: 5), onTimeout: () {
          throw Exception('서버 응답 지연');
        });
      }
    } catch (e) {
      _errorMessage = _appMode == AppMode.standalone
          ? '로컬 DB 오류: $e'
          : '서버 연결 실패: $e';
      _stats = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchTrafficReports() async {
    if (!isConfigured) return;
    _isLoading = true;
    notifyListeners();
    try {
      if (_appMode == AppMode.standalone) {
        _trafficReports = await LocalDbService.getReportsByCategory(
          'traffic',
          excludeWithdraw: _excludeWithdraw,
          normalizePolice: _normalizePolice,
        );
      } else {
        _trafficReports = await _api.getReports('traffic');
      }
    } catch (e) {
      _errorMessage = '교통위반 내역 로드 실패: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchParkingReports() async {
    if (!isConfigured) return;
    _isLoading = true;
    notifyListeners();
    try {
      if (_appMode == AppMode.standalone) {
        _parkingReports = await LocalDbService.getReportsByCategory(
          'parking',
          excludeWithdraw: _excludeWithdraw,
          normalizePolice: _normalizePolice,
        );
      } else {
        _parkingReports = await _api.getReports('parking');
      }
    } catch (e) {
      _errorMessage = '주정차위반 내역 로드 실패: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchOtherReports() async {
    if (!isConfigured) return;
    _isLoading = true;
    notifyListeners();
    try {
      if (_appMode == AppMode.standalone) {
        _otherReports = await LocalDbService.getReportsByCategory(
          'other',
          excludeWithdraw: _excludeWithdraw,
          normalizePolice: _normalizePolice,
        );
      } else {
        _otherReports = await _api.getReports('other');
      }
    } catch (e) {
      _errorMessage = '기타위반 내역 로드 실패: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchDuplicateReports() async {
    if (!isConfigured) return;
    _isLoading = true;
    notifyListeners();
    try {
      if (_appMode == AppMode.standalone) {
        _duplicateReports = await LocalDbService.getDuplicateVehicleReports(
          excludeWithdraw: _excludeWithdraw,
          normalizePolice: _normalizePolice,
        );
      } else {
        _duplicateReports = await _api.getReports('duplicates');
      }
    } catch (e) {
      _errorMessage = '중복차량 내역 로드 실패: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchWatchlistNumbers() async {
    if (!isConfigured) return;
    try {
      if (_appMode == AppMode.standalone) {
        _watchlistNumbers = await LocalDbService.getWatchlistNumbers();
      } else {
        final reports = await _api.getWatchlist();
        _watchlistNumbers = reports.map((r) => r.reportNumber).toSet();
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> addToWatchlist(List<String> reportNumbers) async {
    if (_appMode == AppMode.standalone) {
      _watchlistNumbers.addAll(reportNumbers);
      await LocalDbService.setWatchlistNumbers(_watchlistNumbers);
    } else {
      await _api.updateWatchlist(reportNumbers, add: true);
      _watchlistNumbers.addAll(reportNumbers);
    }
    notifyListeners();
  }

  Future<void> removeFromWatchlist(List<String> reportNumbers) async {
    if (_appMode == AppMode.standalone) {
      _watchlistNumbers.removeAll(reportNumbers);
      await LocalDbService.setWatchlistNumbers(_watchlistNumbers);
    } else {
      await _api.updateWatchlist(reportNumbers, add: false);
      _watchlistNumbers.removeAll(reportNumbers);
    }
    notifyListeners();
  }

  Future<void> enqueueCrawl(String reportNumber) async {
    await _api.enqueueCrawl(reportNumber);
  }

  Future<void> startCrawlQueue(List<String> reportNumbers) async {
    String crawlType = 'api';
    String crawlMode = 'full';
    int maxEmptyPages = 3;
    try {
      final config = await _api.getCrawlConfig();
      crawlType = config['crawl_type']?.toString() ?? 'api';
      crawlMode = config['crawl_mode']?.toString() ?? 'full';
      maxEmptyPages = (config['max_empty_pages'] as num?)?.toInt() ?? 3;
    } catch (_) {}
    await _api.startCrawl(
      loginMode: 'member',
      crawlType: crawlType,
      crawlMode: crawlMode,
      maxEmptyPages: maxEmptyPages,
      queueList: reportNumbers.join('\n'),
    );
  }

  Future<void> refreshAll() async {
    if (!isConfigured) return;
    _errorMessage = null;
    if (_appMode == AppMode.standalone) {
      // sqflite 는 단일 connection 으로 모든 작업을 직렬화하므로
      // Future.wait 로 6개를 동시에 던지면 큐만 가득 차서 fetchSummary 의
      // 5초 timeout 이 발동 (실제 deadlock 아님). 순차 실행으로 변경.
      await fetchSummary();
      await fetchTrafficReports();
      await fetchParkingReports();
      await fetchOtherReports();
      await fetchDuplicateReports();
      await fetchWatchlistNumbers();
    } else {
      await Future.wait([
        fetchSummary(),
        fetchTrafficReports(),
        fetchParkingReports(),
        fetchOtherReports(),
        fetchWatchlistNumbers(),
        fetchAppConfig(),
      ]);
    }
  }
}
