import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_mode.dart';
import '../models/rating_batch_result.dart';
import '../models/report.dart';
import '../services/api_service.dart';
import '../services/app_prefs_keys.dart';
import '../services/local_db_service.dart';
import '../services/permission_service.dart';
import '../services/rating_service.dart';
import '../services/standalone_auth_service.dart';
import '../services/standalone_auto_sync_service.dart';
import '../services/sync_engine.dart';

const _defaultStatusOrder = <String>[
  '수용',
  '일부수용',
  '불수용',
  '처리중',
  '보완요청',
  '취하',
  '기타',
  '답변완료',
];

String _canonicalStatusLabel(String status) {
  final trimmed = status.trim();
  if (trimmed == '진행' || trimmed == '진행중' || trimmed == '처리중') {
    return '처리중';
  }
  return trimmed;
}

const kEmptyLawFilterValue = '__없음__';
const _recentAnswerStatuses = <String>{'수용', '일부수용', '불수용', '기타', '답변완료'};

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
  final String supplementCount;
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
  final String pollStatus;

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
    this.supplementCount = '',
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
    this.pollStatus = '',
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
      supplementCount.isEmpty &&
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
      !onlyPolice &&
      pollStatus.isEmpty;

  /// 활성 필터 항목 요약 (Chip 표시용)
  List<String> get activeLabels {
    final list = <String>[];
    if (name.isNotEmpty) list.add('신고명: $name');
    if (reportNumber.isNotEmpty) list.add('신고번호: $reportNumber');
    if (ratings.isNotEmpty) {
      list.add(
        '별점: ${ratings.map((rating) => rating == '__none__' ? '없음' : '$rating점').join(', ')}',
      );
    }
    if (ratingCause.isNotEmpty) list.add('별점사유: $ratingCause');
    if (agency.isNotEmpty) list.add('기관: $agency');
    if (manager.isNotEmpty) list.add('담당자: $manager');
    if (carNumber.isNotEmpty) list.add('차량: $carNumber');
    if (law == kEmptyLawFilterValue) {
      list.add('위반법규: 없음');
    } else if (law.isNotEmpty) {
      list.add('위반법규: $law');
    }
    if (location.isNotEmpty) list.add('위반장소: $location');
    if (fine.isNotEmpty) list.add('범칙금/과태료: $fine');
    if (supplementCount.isNotEmpty) list.add('보완횟수: $supplementCount');
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
    if (pollStatus.isNotEmpty) list.add('만족도: $pollStatus');
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

  /// 카테고리별로 한 번이라도 fetch 했는지 여부. `ensureCategoryReportsLoaded`
  /// 가 캐시 hit/miss 판정에 사용한다.
  final Set<String> _loadedCategories = <String>{};

  ReportFilter _filter = const ReportFilter();
  bool _excludeWithdraw = true;
  bool _normalizePolice = true;
  bool _useRepresentativeRecords = true;

  // 탭 전환 시 내부 state 가 있는 화면(통계/파일)이 재로드하도록 바꾸는 nonce.
  // 화면들은 이 값을 watch 하다가 변경 시 refresh 를 수행.
  int _statsRefreshNonce = 0;
  int _filesRefreshNonce = 0;
  int _sunwiRefreshNonce = 0;
  int get statsRefreshNonce => _statsRefreshNonce;
  int get filesRefreshNonce => _filesRefreshNonce;
  int get sunwiRefreshNonce => _sunwiRefreshNonce;
  void bumpStatsRefresh() {
    _statsRefreshNonce++;
    notifyListeners();
  }

  void bumpFilesRefresh() {
    _filesRefreshNonce++;
    notifyListeners();
  }

  void bumpSunwiRefresh() {
    _sunwiRefreshNonce++;
    notifyListeners();
  }

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
  bool get useRepresentativeRecords => _useRepresentativeRecords;
  List<Report> get trafficReports => _trafficReports;
  List<Report> get parkingReports => _parkingReports;
  List<Report> get otherReports => _otherReports;
  List<Report> get duplicateReports => _duplicateReports;
  Set<String> get watchlistNumbers => _watchlistNumbers;
  bool isInWatchlist(String reportNumber) =>
      _watchlistNumbers.contains(reportNumber);
  static const _kCoreCategories = ['traffic', 'parking', 'other'];

  bool get hasLoadedCategoryReports =>
      _kCoreCategories.every(_loadedCategories.contains);

  List<Report> get recentAnswerReports {
    if (!hasLoadedCategoryReports) {
      return _stats?.recentAnswers ?? const <Report>[];
    }

    final today = DateTime.now();
    final lowerBound = _formatDateOnly(today.subtract(const Duration(days: 3)));
    final upperBound = _formatDateOnly(today);
    final byReportNumber = <String, Report>{};

    for (final report in [
      ..._trafficReports,
      ..._parkingReports,
      ..._otherReports,
    ]) {
      if (!_isRecentAnswerReport(
        report,
        lowerBound: lowerBound,
        upperBound: upperBound,
      )) {
        continue;
      }

      final key = report.reportNumber.isNotEmpty
          ? report.reportNumber
          : '${report.category}:${report.name}:${report.responseDate}';
      final existing = byReportNumber[key];
      if (existing == null ||
          _compareRecentAnswerReports(report, existing) < 0) {
        byReportNumber[key] = report;
      }
    }

    final items = byReportNumber.values.toList();
    items.sort(_compareRecentAnswerReports);
    return items;
  }

  /// 신고번호로 카테고리(traffic/parking/other)를 추정.
  /// 1) Report.category 가 채워져 있으면 그대로 사용
  /// 2) 그렇지 않으면 현재 로드된 카테고리 리스트에서 매칭되는 것 검색
  String? findCategory(Report report) {
    final fromModel = report.category.trim();
    if (fromModel == 'traffic' ||
        fromModel == 'parking' ||
        fromModel == 'other') {
      return fromModel;
    }
    final number = report.reportNumber;
    if (number.isEmpty) return null;
    if (_trafficReports.any((r) => r.reportNumber == number)) return 'traffic';
    if (_parkingReports.any((r) => r.reportNumber == number)) return 'parking';
    if (_otherReports.any((r) => r.reportNumber == number)) return 'other';
    return null;
  }

  int categoryToTabIndex(String? category) {
    switch (category) {
      case 'parking':
        return 1;
      case 'other':
        return 2;
      default:
        return 0;
    }
  }

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
        final status = _canonicalStatusLabel(report.status);
        if (status.isEmpty || !seen.add(status)) continue;
        discovered.add(status);
      }
    }

    collect(_trafficReports);
    collect(_parkingReports);
    collect(_otherReports);
    for (final status in _filter.statuses) {
      final trimmed = _canonicalStatusLabel(status);
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      discovered.add(trimmed);
    }

    final preferred = _defaultStatusOrder.where(seen.contains).toList();
    final extras =
        discovered
            .where((status) => !_defaultStatusOrder.contains(status))
            .toList()
          ..sort((a, b) => a.compareTo(b));
    return [...preferred, ...extras];
  }

  List<String> get availableLaws {
    final seen = <String>{};
    final discovered = <String>[];
    var hasEmptyLaw = false;

    void collect(Iterable<Report> reports) {
      for (final report in reports) {
        final law = report.law.trim();
        if (law.isEmpty) {
          hasEmptyLaw = true;
          continue;
        }
        if (!seen.add(law)) continue;
        discovered.add(law);
      }
    }

    collect(_trafficReports);
    collect(_parkingReports);
    collect(_otherReports);

    final selectedLaw = _filter.law.trim();
    if (selectedLaw == kEmptyLawFilterValue) {
      hasEmptyLaw = true;
    } else if (selectedLaw.isNotEmpty && seen.add(selectedLaw)) {
      discovered.add(selectedLaw);
    }

    discovered.sort((a, b) => a.compareTo(b));
    if (hasEmptyLaw) {
      discovered.insert(0, kEmptyLawFilterValue);
    }
    return discovered;
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
      _parseAndOrGroups(query).any(
        (group) => group.every((term) => source.toLowerCase().contains(term)),
      );

  String _formatDateOnly(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }

  String? _extractDateOnly(String raw) {
    final match = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(raw.trim());
    return match?.group(1);
  }

  int _compareRecentAnswerReports(Report left, Report right) {
    final leftSynced = left.syncedAt ?? -1;
    final rightSynced = right.syncedAt ?? -1;
    if (leftSynced != rightSynced) {
      return rightSynced.compareTo(leftSynced);
    }
    final responseComp = right.responseDate.compareTo(left.responseDate);
    if (responseComp != 0) return responseComp;
    return right.reportNumber.compareTo(left.reportNumber);
  }

  bool _isRecentAnswerReport(
    Report report, {
    required String lowerBound,
    required String upperBound,
  }) {
    final status = report.status.trim();
    if (!_recentAnswerStatuses.contains(status)) return false;

    final responseDate = _extractDateOnly(report.responseDate);
    if (responseDate == null || responseDate.isEmpty) return false;

    return responseDate.compareTo(lowerBound) >= 0 &&
        responseDate.compareTo(upperBound) <= 0;
  }

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
        final ratingToken = (r.rating == null || r.rating! <= 0)
            ? '__none__'
            : r.rating.toString();
        if (!f.ratings.contains(ratingToken)) return false;
      }
      if (!_contains(r.ratingCause, f.ratingCause)) return false;
      if (!_contains(r.agency, f.agency)) return false;
      if (!_contains(r.manager, f.manager)) return false;
      if (!_contains(r.carNumber, f.carNumber)) return false;
      if (f.law == kEmptyLawFilterValue) {
        if (r.law.trim().isNotEmpty) return false;
      } else if (f.law.isNotEmpty && r.law.trim() != f.law) {
        return false;
      }
      if (!_contains(r.location, f.location)) return false;
      if (!_contains(r.fineInfo, f.fine)) return false;
      if (!_contains(r.supplementCount.toString(), f.supplementCount)) {
        return false;
      }
      if (!_contains(r.reportContent, f.reportContent)) return false;
      if (!_contains(r.processContent, f.processContent)) return false;
      if (f.statuses.isNotEmpty &&
          !f.statuses.contains(_canonicalStatusLabel(r.status))) {
        return false;
      }
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
      if (f.pollStatus.isNotEmpty && r.pollStatus.trim() != f.pollStatus) {
        return false;
      }
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
      _useRepresentativeRecords =
          prefs.getBool('standaloneUseRepresentativeRecords') ?? true;
      notifyListeners();
      return;
    }
    try {
      final cfg = await _api.getAppConfig();
      _excludeWithdraw = cfg['exclude_withdraw'] as bool? ?? false;
      _normalizePolice = cfg['normalize_police'] as bool? ?? false;
      _useRepresentativeRecords =
          cfg['use_representative_records'] as bool? ?? true;
      notifyListeners();
    } catch (_) {}
  }

  /// standalone 전용 설정 토글 — SharedPreferences 영속화 + 데이터 재로드
  Future<void> setStandaloneFilter({
    bool? excludeWithdraw,
    bool? normalizePolice,
    bool? useRepresentativeRecords,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (excludeWithdraw != null) {
      _excludeWithdraw = excludeWithdraw;
      await prefs.setBool('standaloneExcludeWithdraw', excludeWithdraw);
    }
    if (normalizePolice != null) {
      _normalizePolice = normalizePolice;
      await prefs.setBool('standaloneNormalizePolice', normalizePolice);
    }
    if (useRepresentativeRecords != null) {
      _useRepresentativeRecords = useRepresentativeRecords;
      await prefs.setBool(
        'standaloneUseRepresentativeRecords',
        useRepresentativeRecords,
      );
    }
    notifyListeners();
    await refreshAll();
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      _appMode = AppModeX.fromString(prefs.getString(AppPrefsKeys.appMode));
      _standaloneUsername =
          prefs.getString(AppPrefsKeys.standaloneUsername) ?? '';
      _standalonePhoneNumber =
          prefs.getString(AppPrefsKeys.standalonePhoneNumber) ?? '';
      _isStandaloneDemo =
          prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false;
      _baseUrl = prefs.getString(AppPrefsKeys.baseUrl) ?? '';
      _apiKey = prefs.getString(AppPrefsKeys.apiKey) ?? '';

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
    final cleanUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    _appMode = AppMode.server;
    _isStandaloneDemo = false;
    _baseUrl = cleanUrl;
    _apiKey = key;
    _errorMessage = null;
    _loadedCategories.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppPrefsKeys.appMode, AppMode.server.name);
    await prefs.setString(AppPrefsKeys.baseUrl, _baseUrl);
    await prefs.setString(AppPrefsKeys.apiKey, _apiKey);
    await prefs.remove(AppPrefsKeys.standaloneDemoMode);

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
    _loadedCategories.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppPrefsKeys.appMode, AppMode.standalone.name);
    await prefs.setString(AppPrefsKeys.standaloneUsername, username);
    await prefs.setString(
      AppPrefsKeys.standalonePhoneNumber,
      _standalonePhoneNumber,
    );
    await prefs.setBool(AppPrefsKeys.standaloneDemoMode, isDemoMode);

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
    _loadedCategories.clear();
    _errorMessage = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppPrefsKeys.appMode);
    await prefs.remove(AppPrefsKeys.baseUrl);
    await prefs.remove(AppPrefsKeys.apiKey);
    await prefs.remove(AppPrefsKeys.standaloneUsername);
    await prefs.remove(AppPrefsKeys.standalonePhoneNumber);
    await prefs.remove(AppPrefsKeys.standaloneDemoMode);
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
        _stats =
            await LocalDbService.computeSummary(
              excludeWithdraw: _excludeWithdraw,
              normalizePolice: _normalizePolice,
              useRepresentativeRecords: _useRepresentativeRecords,
            ).timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                throw Exception('로컬 DB 응답 지연 (데드락 의심)');
              },
            );
      } else {
        _stats = await _api.getSummary().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw Exception('서버 응답 지연');
          },
        );
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

  /// 카테고리 별 fetch 공통 경로 — 모드 분기와 결과 저장만 다르고 형태는 동일.
  /// `traffic` / `parking` / `other` 만 정식 카테고리. 알 수 없는 값은 무시.
  Future<void> fetchCategoryReports(String category) async {
    if (!isConfigured) return;
    if (!_kCoreCategories.contains(category)) return;
    _isLoading = true;
    notifyListeners();
    try {
      final reports = _appMode == AppMode.standalone
          ? await LocalDbService.getReportsByCategory(
              category,
              excludeWithdraw: _excludeWithdraw,
              normalizePolice: _normalizePolice,
              useRepresentativeRecords: _useRepresentativeRecords,
            )
          : await _api.getReports(category);
      switch (category) {
        case 'traffic':
          _trafficReports = reports;
          break;
        case 'parking':
          _parkingReports = reports;
          break;
        case 'other':
          _otherReports = reports;
          break;
      }
      _loadedCategories.add(category);
    } catch (e) {
      _errorMessage = '${_categoryLabel(category)} 내역 로드 실패: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  static String _categoryLabel(String category) {
    switch (category) {
      case 'traffic':
        return '교통위반';
      case 'parking':
        return '주정차위반';
      case 'other':
        return '기타위반';
      default:
        return category;
    }
  }

  // 기존 API 호환 — 화면 측은 카테고리 이름을 직접 알지 않아도 되도록 thin wrapper 유지.
  Future<void> fetchTrafficReports() => fetchCategoryReports('traffic');
  Future<void> fetchParkingReports() => fetchCategoryReports('parking');
  Future<void> fetchOtherReports() => fetchCategoryReports('other');

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

  Future<void> ensureCategoryReportsLoaded({bool forceRefresh = false}) async {
    if (!isConfigured) return;

    final pending = _kCoreCategories
        .where((c) => forceRefresh || !_loadedCategories.contains(c))
        .toList();
    if (pending.isEmpty) return;

    if (_appMode == AppMode.standalone) {
      // Standalone 은 sqflite 단일 connection 이라 직렬 실행. (자세한 배경은 CLAUDE.md
      // 의 "refreshAll 직렬화" 절 참조.)
      for (final c in pending) {
        await fetchCategoryReports(c);
      }
      return;
    }

    await Future.wait(pending.map(fetchCategoryReports));
  }

  Future<void> refreshSummaryAndRecentAnswers() async {
    if (!isConfigured) return;
    await fetchSummary();
    await ensureCategoryReportsLoaded(forceRefresh: true);
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

  Future<RatingBatchResult> submitRatings(
    List<Report> reports, {
    required int score,
  }) async {
    final result = await RatingService.submit(
      appMode: _appMode,
      selectedReports: reports,
      score: score,
      api: _appMode == AppMode.server ? _api : null,
      isStandaloneDemo: _isStandaloneDemo,
    );

    try {
      await refreshAll();
      final reportLookup = <String, Report>{};
      for (final report in [
        ..._trafficReports,
        ..._parkingReports,
        ..._otherReports,
        ..._duplicateReports,
      ]) {
        reportLookup[report.reportNumber] = report;
      }
      return result.enrichWithReports(reportLookup);
    } catch (_) {
      return result;
    }
  }

  Future<void> refreshAll() async {
    if (!isConfigured) return;
    _errorMessage = null;
    if (_appMode == AppMode.standalone) {
      // sqflite 는 단일 connection 으로 모든 작업을 직렬화하므로
      // Future.wait 로 동시에 던지면 큐만 가득 차서 fetchSummary 의
      // 5초 timeout 이 발동 (실제 deadlock 아님). 순차 실행으로 변경.
      await fetchSummary();
      for (final c in _kCoreCategories) {
        await fetchCategoryReports(c);
      }
      await fetchDuplicateReports();
      await fetchWatchlistNumbers();
    } else {
      await Future.wait([
        fetchSummary(),
        ..._kCoreCategories.map(fetchCategoryReports),
        fetchWatchlistNumbers(),
        fetchAppConfig(),
      ]);
    }
  }

  List<Report> applyFilterToReports(List<Report> reports) =>
      _applyFilter(reports);
}
