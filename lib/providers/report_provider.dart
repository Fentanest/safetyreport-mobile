export '../models/report_filter.dart';
import '../models/report_filter.dart';
import '../services/client_compatibility.dart';
import '../services/performance_trace.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_mode.dart';
import '../models/app_theme_mode.dart';
import '../models/rating_batch_result.dart';
import '../models/report.dart';
import '../community/upload_hooks.dart';
import '../community/rebuild/community_rebuild.dart' show CommunityRebuildGuard;
import '../services/api_service.dart';
import '../services/app_prefs_keys.dart';
import '../services/community_auth_service.dart';
import '../services/local_db_service.dart';
import '../services/maintenance_service.dart';
import '../services/permission_service.dart';
import '../services/rating_service.dart';
import '../services/background_login_check.dart';
import '../services/review_prompt_service.dart';
import '../services/standalone_auth_service.dart';
import '../services/standalone_auto_sync_service.dart';
import '../services/sync_engine.dart';
import '../services/server_contract.dart';

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
  if (trimmed == '진행' ||
      trimmed == '진행중' ||
      trimmed == '검토중' ||
      trimmed == '처리중') {
    return '처리중';
  }
  return trimmed;
}

const _recentAnswerStatuses = <String>{'수용', '일부수용', '불수용', '기타', '답변완료'};

class ReportProvider with ChangeNotifier {
  AppMode _appMode = AppMode.server;
  AppThemeMode _themeMode = AppThemeMode.system;
  String _standaloneUsername = '';
  String _standalonePhoneNumber = '';
  bool _isStandaloneDemo = false;
  String _baseUrl = '';
  String _apiKey = '';
  int _datasetEpoch = 0;
  int get datasetEpoch => _datasetEpoch;
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _errorMessage;
  DashboardStats? _stats;
  List<Report> _trafficReports = [];
  List<Report> _parkingReports = [];
  List<Report> _otherReports = [];
  List<Report> _duplicateReports = [];
  Set<String> _watchlistNumbers = {};
  List<String> _filterStatuses = [];
  List<String> _filterLaws = [];

  /// Legacy callers keep only a 200-row preview, never the full category.
  /// Real list/search/editor screens own their SQL/server pages.
  final Set<String> _loadedCategories = <String>{};
  Future<void>? _summaryLoadFuture;
  final Map<String, Future<void>> _categoryLoadFutures =
      <String, Future<void>>{};
  Future<void>? _duplicateLoadFuture;
  Future<void>? _watchlistLoadFuture;
  Future<void>? _appConfigLoadFuture;

  /// 서버가 `/api/v1/app/config` 의 `capabilities` 로 알린 기능(Client 모드). 구서버는 빈 목록.
  List<String> _serverCapabilities = const [];

  /// 별점 공통 사유를 보낼 수 있는가 — Standalone 은 항상, Client 는 서버가 rating_cause 를 알릴 때만.
  bool get ratingCauseSupported =>
      _appMode == AppMode.standalone ||
      _serverCapabilities.contains('rating_cause');

  /// 연결된 서버가 "서버의 커뮤니티 계정" API 를 알리는가(Client 모드). 구서버는 false.
  bool get communityAccountSupported =>
      _appMode == AppMode.server &&
      _serverCapabilities.contains(ServerContract.communityAccountCapability);

  ReportFilter _filter = const ReportFilter();
  bool _excludeWithdraw = true;
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
  AppThemeMode get themeMode => _themeMode;
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

  /// 알림 상세처럼 목록보다 최신인 [report]를 기준으로 검색 화면에
  /// 진입할 때, 해당 카테고리의 캐시를 먼저 새로 고친다.
  ///
  /// 카테고리 정보가 없으면 최신 목록 전체에서 한 번 더 찾는다.
  Future<String?> refreshCategoryForReport(Report report) async {
    final category = findCategory(report);
    if (category != null) {
      await fetchCategoryReports(category);
      return category;
    }

    return resolveReportCategory(report);
  }

  /// Unknown notification categories are resolved without retaining all reports.
  Future<String?> resolveReportCategory(Report report) async {
    final epoch = _datasetEpoch;
    if (_appMode == AppMode.standalone) {
      final found = await LocalDbService.getReportByNumber(report.reportNumber);
      return epoch == _datasetEpoch ? found?.category : null;
    }
    // The canonical server has category pages, but no single-report lookup.
    // This rare, explicit navigation fallback holds at most one 200-row page.
    for (final category in _kCoreCategories) {
      var offset = 0;
      while (epoch == _datasetEpoch) {
        final page = await _api.getReportsPage(
          category,
          offset: offset,
          dedupe: 'raw',
        );
        if (epoch != _datasetEpoch) return null;
        if (page.reports.any((r) => r.reportNumber == report.reportNumber)) {
          return category;
        }
        offset += page.reports.length;
        if (page.reports.isEmpty || offset >= page.total) break;
      }
    }
    return null;
  }

  /// Refresh compact filter metadata without Report bodies; local values use DISTINCT.
  Future<void> fetchFilterOptions() async {
    if (!isConfigured) return;
    final epoch = _datasetEpoch;
    final options = _appMode == AppMode.standalone
        ? await LocalDbService.getFilterOptions()
        : await _api.getFilterOptions();
    if (epoch != _datasetEpoch) return;
    _filterStatuses = _appMode == AppMode.standalone
        ? options.statuses
        : {..._filterStatuses, ...options.statuses}.toList();
    _filterLaws = _appMode == AppMode.standalone
        ? options.laws
        : {..._filterLaws, ...options.laws}.toList();
    notifyListeners();
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
  List<Report> get ratingEligibleReports => _sortRatingReports(
    [
      ..._trafficReports,
      ..._parkingReports,
      ..._otherReports,
    ].where(RatingService.isListEligible),
  );
  List<Report> get filteredRatingEligibleReports => _sortRatingReports(
    _applyFilter(
      ratingEligibleReports,
      filter: _filter.withoutRatingStateFilters(),
    ),
  );
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

    for (final value in _filterStatuses) {
      final status = _canonicalStatusLabel(value);
      if (status.isNotEmpty && seen.add(status)) discovered.add(status);
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

    for (final law in _filterLaws) {
      if (law.isEmpty || law == kEmptyLawFilterValue) {
        hasEmptyLaw = true;
      } else if (seen.add(law)) {
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

  List<Report> _sortRatingReports(Iterable<Report> reports) {
    final items = reports.toList(growable: false);
    items.sort((left, right) {
      final reportNumberComp = right.reportNumber.compareTo(left.reportNumber);
      if (reportNumberComp != 0) return reportNumberComp;
      final syncedLeft = left.syncedAt ?? -1;
      final syncedRight = right.syncedAt ?? -1;
      if (syncedLeft != syncedRight) {
        return syncedRight.compareTo(syncedLeft);
      }
      return right.date.compareTo(left.date);
    });
    return items;
  }

  List<Report> _applyFilter(List<Report> reports, {ReportFilter? filter}) {
    final f = filter ?? _filter;
    return reports.where((r) {
      if (!_contains(r.name, f.name)) return false;
      if (!_contains(r.reportNumber, f.reportNumber)) return false;
      if (!_contains(r.id, f.id)) return false;
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

  Future<void> fetchAppConfig() {
    if (!isConfigured) return Future.value();
    final inFlight = _appConfigLoadFuture;
    if (inFlight != null) return inFlight;
    final future = _fetchAppConfigImpl();
    _appConfigLoadFuture = future;
    return future.whenComplete(() {
      if (identical(_appConfigLoadFuture, future)) {
        _appConfigLoadFuture = null;
      }
    });
  }

  Future<void> _fetchAppConfigImpl() async {
    final epoch = _datasetEpoch;
    if (_appMode == AppMode.standalone) {
      final prefs = await SharedPreferences.getInstance();
      if (epoch != _datasetEpoch) return;
      _excludeWithdraw = prefs.getBool('standaloneExcludeWithdraw') ?? true;
      _useRepresentativeRecords =
          prefs.getBool('standaloneUseRepresentativeRecords') ?? true;
      notifyListeners();
      return;
    }
    try {
      final cfg = await _api.getAppConfig();
      if (epoch != _datasetEpoch) return;
      _excludeWithdraw = cfg['exclude_withdraw'] as bool? ?? false;
      _useRepresentativeRecords =
          cfg['use_representative_records'] as bool? ?? true;
      _serverCapabilities = [
        for (final c in (cfg['capabilities'] as List? ?? const [])) '$c',
      ];
      notifyListeners();
    } catch (_) {}
  }

  /// standalone 전용 설정 토글 — SharedPreferences 영속화 + 데이터 재로드
  Future<void> setStandaloneFilter({
    bool? excludeWithdraw,
    bool? useRepresentativeRecords,
  }) async {
    if ((excludeWithdraw != null && excludeWithdraw != _excludeWithdraw) ||
        (useRepresentativeRecords != null &&
            useRepresentativeRecords != _useRepresentativeRecords)) {
      _datasetEpoch++;
      _resetDatasetView();
    }
    final prefs = await SharedPreferences.getInstance();
    if (excludeWithdraw != null) {
      _excludeWithdraw = excludeWithdraw;
      await prefs.setBool('standaloneExcludeWithdraw', excludeWithdraw);
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
      _themeMode = AppThemeModeX.fromString(
        prefs.getString(AppPrefsKeys.themeMode),
      );
      _standaloneUsername =
          prefs.getString(AppPrefsKeys.standaloneUsername) ?? '';
      _standalonePhoneNumber =
          prefs.getString(AppPrefsKeys.standalonePhoneNumber) ?? '';
      _isStandaloneDemo =
          prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false;
      _baseUrl = prefs.getString(AppPrefsKeys.baseUrl) ?? '';
      _apiKey = prefs.getString(AppPrefsKeys.apiKey) ?? '';
      await prefs.remove(AppPrefsKeys.standaloneKakaoRestApiKey);

      _changesEmittedSub ??= SyncEngine.changesEmitted.listen((_) {
        _pendingChangesNonce++;
        notifyListeners();
      });

      // 게이트 전에는 설정 로드만 한다. BackgroundLoginCheck 예약·drain·자동 동기화·
      // WsService 시작은 게이트 통과 뒤 onGatePassed() 에서 1회 실행한다.
    } catch (e) {
      _errorMessage = '초기화 실패: $e';
      ReviewPromptService.markSessionError();
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  /// 테스트 주입용 훅. null 이면 실제 서비스를 부른다.
  /// F18: 게이트 전에는 이 훅들이 호출되지 않아야 한다.
  static Future<void> Function()? scheduleLoginCheckHook;
  static Future<void> Function()? drainAndRefreshHook;
  static Future<bool> Function()? startWsServiceHook;

  String ratingCauseDraft = '';
  final _ratingInFlight = <String>{};
  bool _gatePassed = false;

  void _resetDatasetView() {
    _stats = null;
    _trafficReports = [];
    _parkingReports = [];
    _otherReports = [];
    _duplicateReports = [];
    _watchlistNumbers = {};
    _filterStatuses = [];
    _filterLaws = [];
    _loadedCategories.clear();
    _summaryLoadFuture = null;
    _categoryLoadFutures.clear();
    _duplicateLoadFuture = null;
    _watchlistLoadFuture = null;
  }

  /// 카카오 인증·동의가 풀리면 Client의 백그라운드 서버 연결도 끊는다.
  void onGateBlocked() {
    _datasetEpoch++;
    _resetDatasetView();
    _gatePassed = false;
    _stats = null;
    _trafficReports = [];
    _parkingReports = [];
    _otherReports = [];
    _duplicateReports = [];
    _filterStatuses = [];
    _filterLaws = [];
    _loadedCategories.clear();
    notifyListeners();
    if (_appMode == AppMode.server) {
      unawaited(PermissionService.stopWsService());
    }
  }

  /// 게이트가 ok 로 처음 바뀔 때 1회 + 이후 resume(`CommunityGate.addOnFirstPassed` 연결).
  /// T6 의 `registerBackgroundJobs()`·`catchUp('resume')` 도 여기서 부른다.
  Future<void> onGatePassed() async {
    if (_gatePassed) return;
    _gatePassed = true;
    try {
      if (!isConfigured) return;
      if (_appMode == AppMode.standalone) {
        if (!_isStandaloneDemo) {
          await StandaloneAuthService.reloadStatus();
          StandaloneAuthService.startKeepAlive();
          if (scheduleLoginCheckHook != null) {
            await scheduleLoginCheckHook!();
          } else {
            unawaited(BackgroundLoginCheck.schedule());
          }
          fetchWatchlistNumbers();
          fetchAppConfig();
          try {
            await refreshAll();
          } catch (_) {
            // 로컬 표시 갱신 실패는 drain·예약을 막지 않는다.
          }
          if (!_isStandaloneDemo) {
            await _drainAndRefresh();
          }
        } else {
          try {
            await refreshAll();
          } catch (_) {}
        }
      } else {
        fetchWatchlistNumbers();
        fetchAppConfig();
        if (startWsServiceHook != null) {
          await startWsServiceHook!();
        } else {
          unawaited(PermissionService.startWsService());
        }
      }
      // 업로드·자정 작업은 Standalone writer(데모 제외)만. Client·데모는 등록된 작업을 해제한다.
      if (_appMode == AppMode.standalone && !_isStandaloneDemo) {
        await CommunityUploadHooks.registerBackgroundJobsNow();
        await CommunityUploadHooks.catchUpNow('gate-passed');
      } else {
        await CommunityUploadHooks.cancelBackgroundJobsNow();
      }
    } catch (e) {
      _errorMessage = '게이트 통과 후 시작 실패: $e';
      notifyListeners();
    }
  }

  /// 테스트·게이트 상실 복귀용. 다음 onGatePassed() 가 다시 실행된다.
  void resetGatePassedForTest() {
    _gatePassed = false;
  }

  @override
  void dispose() {
    _changesEmittedSub?.cancel();
    StandaloneAuthService.stopKeepAlive();
    super.dispose();
  }

  /// foreground 복귀 시 호출 (main.dart AppLifecycleState.resumed).
  /// 초기화 필요·진행 중에는 자동 동기화 시작을 막고 조회만 한다.
  Future<void> checkAutoSyncOnResume() async {
    if (_appMode != AppMode.standalone || !isConfigured) return;
    if (_isStandaloneDemo) {
      await refreshAll();
      return;
    }
    if (!_gatePassed) return;
    // 백그라운드 로그인 점검(다른 isolate)이 남긴 결과를 화면에 반영한다.
    await StandaloneAuthService.reloadStatus();
    StandaloneAuthService.startKeepAlive();
    await StandaloneAuthService.refreshSessionIfNeeded();
    // 앱 복귀: 재시도 시각이 지난 공유 업로드를 바로 이어서(초기화 중에도 — 업로드는 수집과 별개).
    CommunityUploadHooks.wakeUploadNow('recovery');
    if (CommunityRebuildGuard.active) return;
    await _drainAndRefresh();
  }

  /// drain 트리거 + UI 갱신. onGatePassed() 와 checkAutoSyncOnResume 공통.
  /// 큐가 비어있으면 drainIfPending 첫 iteration 에서 즉시 break 하므로 비용 거의 없음.
  Future<void> _drainAndRefresh() async {
    if (drainAndRefreshHook != null) {
      await drainAndRefreshHook!();
      return;
    }
    await StandaloneAutoSyncService.drainIfPending();
    if (_appMode == AppMode.standalone) await refreshAll();
  }

  Future<void> setConfig(String url, String key) async {
    StandaloneAuthService.stopKeepAlive();
    unawaited(BackgroundLoginCheck.cancel());
    unawaited(
      CommunityUploadHooks.cancelBackgroundJobsNow(),
    ); // Client·데모·초기화: 공유 업로드 작업 해제
    final cleanUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    _datasetEpoch++;
    _resetDatasetView();
    ratingCauseDraft = '';
    ClientCompatibility.invalidate();
    _appMode = AppMode.server;
    _isStandaloneDemo = false;
    _baseUrl = cleanUrl;
    _apiKey = key;
    _errorMessage = null;
    _filterStatuses = [];
    _filterLaws = [];
    _loadedCategories.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppPrefsKeys.appMode, AppMode.server.name);
    await prefs.setString(AppPrefsKeys.baseUrl, _baseUrl);
    await prefs.setString(AppPrefsKeys.apiKey, _apiKey);
    await prefs.remove(AppPrefsKeys.standaloneDemoMode);
    await LocalDbService.closeDb();

    notifyListeners();
  }

  Future<void> setStandaloneConfig(
    String username, {
    required String phoneNumber,
    bool isDemoMode = false,
  }) async {
    await PermissionService.stopWsService();
    final wasStandaloneLive =
        _appMode == AppMode.standalone && !_isStandaloneDemo;
    if (!wasStandaloneLive) _gatePassed = false;
    if (isDemoMode) {
      StandaloneAuthService.stopKeepAlive();
      await StandaloneAuthService.clearToken();
      unawaited(BackgroundLoginCheck.cancel());
      unawaited(
        CommunityUploadHooks.cancelBackgroundJobsNow(),
      ); // 데모: 공유 업로드 작업 해제
    } else {
      // 새 모드의 게이트를 통과한 뒤 keep-alive·예약을 시작한다.
      if (!_gatePassed) {
        StandaloneAuthService.stopKeepAlive();
      } else {
        StandaloneAuthService.startKeepAlive();
      }
    }
    _datasetEpoch++;
    _resetDatasetView();
    ratingCauseDraft = '';
    ClientCompatibility.invalidate();
    _appMode = AppMode.standalone;
    _standaloneUsername = username;
    _standalonePhoneNumber = isDemoMode
        ? phoneNumber.trim()
        : phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
    _isStandaloneDemo = isDemoMode;
    _errorMessage = null;
    _filterStatuses = [];
    _filterLaws = [];
    _loadedCategories.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppPrefsKeys.appMode, AppMode.standalone.name);
    await prefs.setString(AppPrefsKeys.standaloneUsername, username);
    await prefs.setString(
      AppPrefsKeys.standalonePhoneNumber,
      _standalonePhoneNumber,
    );
    final wasDemo = prefs.getBool(AppPrefsKeys.standaloneDemoMode) ?? false;
    await prefs.setBool(AppPrefsKeys.standaloneDemoMode, isDemoMode);
    if (wasDemo != isDemoMode) {
      await LocalDbService.closeDb(); // 데모 ↔ 실제 DB 파일 전환(M-24)
    }

    notifyListeners();
  }

  Future<void> setThemeMode(AppThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppPrefsKeys.themeMode, value.name);
    notifyListeners();
  }

  Future<void> resetConfig() async {
    await PermissionService.stopWsService();
    _gatePassed = false;
    StandaloneAuthService.stopKeepAlive();
    unawaited(BackgroundLoginCheck.cancel());
    unawaited(
      CommunityUploadHooks.cancelBackgroundJobsNow(),
    ); // Client·데모·초기화: 공유 업로드 작업 해제
    _datasetEpoch++;
    _resetDatasetView();
    ratingCauseDraft = '';
    ClientCompatibility.invalidate();
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
    _filterStatuses = [];
    _filterLaws = [];
    _loadedCategories.clear();
    _errorMessage = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppPrefsKeys.appMode);
    await prefs.remove(AppPrefsKeys.baseUrl);
    await prefs.remove(AppPrefsKeys.apiKey);
    await prefs.remove(AppPrefsKeys.standaloneKakaoRestApiKey);
    await prefs.remove(AppPrefsKeys.standaloneUsername);
    await prefs.remove(AppPrefsKeys.standalonePhoneNumber);
    await prefs.remove(AppPrefsKeys.standaloneDemoMode);
    await StandaloneAuthService.clearToken();
    // 실제 모드 변경: Standalone 커뮤니티 세션·대기 로그인을 지운다(M05). 서버의 커뮤니티 계정은 건드리지 않는다.
    _serverCapabilities = const [];
    try {
      await CommunityAuthService.instance.clearForModeChange();
    } catch (_) {}
    await LocalDbService.closeDb();

    notifyListeners();
  }

  ApiService get _api => ApiService(baseUrl: _baseUrl, apiKey: _apiKey);

  DashboardStats _normalizeSummaryForFilters(DashboardStats stats) {
    if (stats.excludeWithdraw != true) return stats;
    return stats.copyWith(
      recentAnswers: stats.recentAnswers
          .where((report) => report.status != '취하')
          .toList(),
      watchlist: stats.watchlist
          .where((report) => report.status != '취하')
          .toList(),
    );
  }

  Future<void> fetchSummary() {
    if (!isConfigured) return Future.value();
    final inFlight = _summaryLoadFuture;
    if (inFlight != null) return inFlight;
    final future = _fetchSummaryImpl();
    _summaryLoadFuture = future;
    return future.whenComplete(() {
      if (identical(_summaryLoadFuture, future)) {
        _summaryLoadFuture = null;
      }
    });
  }

  Future<void> _fetchSummaryImpl() async {
    final epoch = _datasetEpoch;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      DashboardStats result;
      if (_appMode == AppMode.standalone) {
        result = _normalizeSummaryForFilters(
          await LocalDbService.computeSummary(
            excludeWithdraw: _excludeWithdraw,
            useRepresentativeRecords: _useRepresentativeRecords,
            isCancelled: () => epoch != _datasetEpoch,
          ),
        );
      } else {
        result = _normalizeSummaryForFilters(
          await _api.getSummary().timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw Exception('서버 응답 지연');
            },
          ),
        );
      }
      if (epoch != _datasetEpoch) return;
      PerformanceTrace.sync('summary.provider_update', () => _stats = result);
    } catch (e) {
      if (epoch != _datasetEpoch) return;
      _errorMessage = _appMode == AppMode.standalone
          ? '로컬 DB 오류: $e'
          : '서버 연결 실패: $e';
      _stats = null;
    } finally {
      if (epoch == _datasetEpoch) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// 카테고리 별 fetch 공통 경로 — 모드 분기와 결과 저장만 다르고 형태는 동일.
  /// `traffic` / `parking` / `other` 만 정식 카테고리. 알 수 없는 값은 무시.
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
  }) async {
    final epoch = _datasetEpoch;
    final page = await _api.getReportsPage(
      category,
      offset: offset,
      limit: limit,
      dedupe: _useRepresentativeRecords ? 'canonical' : 'raw',
    );
    if (epoch == _datasetEpoch) {
      // Preserve custom values discovered on visible pages; keep only metadata.
      _filterStatuses = {
        ..._filterStatuses,
        ...page.reports.map((r) => r.status),
      }.toList();
      _filterLaws = {
        ..._filterLaws,
        ...page.reports.map((r) => r.law),
      }.toList();
    }
    return page;
  }

  Future<void> fetchCategoryReports(String category) {
    if (!isConfigured || !_kCoreCategories.contains(category)) {
      return Future.value();
    }
    final inFlight = _categoryLoadFutures[category];
    if (inFlight != null) return inFlight;
    final future = _fetchCategoryReportsImpl(category);
    _categoryLoadFutures[category] = future;
    return future.whenComplete(() {
      if (identical(_categoryLoadFutures[category], future)) {
        _categoryLoadFutures.remove(category);
      }
    });
  }

  Future<void> _fetchCategoryReportsImpl(String category) async {
    final epoch = _datasetEpoch;
    _isLoading = true;
    notifyListeners();
    try {
      final page = _appMode == AppMode.standalone
          ? await LocalDbService.getReportPage(
              category: category,
              excludeWithdraw: _excludeWithdraw,
              useRepresentativeRecords: _useRepresentativeRecords,
            )
          : await readServerPage(category);
      final reports = page.reports;
      if (epoch != _datasetEpoch) return;
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
      if (epoch != _datasetEpoch) return;
      _errorMessage = '${_categoryLabel(category)} 내역 로드 실패: $e';
      ReviewPromptService.markSessionError();
    } finally {
      if (epoch == _datasetEpoch) {
        _isLoading = false;
        notifyListeners();
      }
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

  Future<void> fetchDuplicateReports() {
    if (!isConfigured) return Future.value();
    final inFlight = _duplicateLoadFuture;
    if (inFlight != null) return inFlight;
    final future = _fetchDuplicateReportsImpl();
    _duplicateLoadFuture = future;
    return future.whenComplete(() {
      if (identical(_duplicateLoadFuture, future)) {
        _duplicateLoadFuture = null;
      }
    });
  }

  Future<void> _fetchDuplicateReportsImpl() async {
    final epoch = _datasetEpoch;
    _isLoading = true;
    notifyListeners();
    try {
      if (_appMode == AppMode.standalone) {
        final loaded = await LocalDbService.getDuplicateVehicleReports(
          excludeWithdraw: _excludeWithdraw,
        );
        if (epoch != _datasetEpoch) return;
        _duplicateReports = loaded;
      } else {
        final loaded = await _api.getReports('duplicates');
        if (epoch != _datasetEpoch) return;
        _duplicateReports = loaded;
      }
    } catch (e) {
      if (epoch != _datasetEpoch) return;
      _errorMessage = '중복차량 내역 로드 실패: $e';
      ReviewPromptService.markSessionError();
    } finally {
      if (epoch == _datasetEpoch) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> fetchWatchlistNumbers() {
    if (!isConfigured) return Future.value();
    final inFlight = _watchlistLoadFuture;
    if (inFlight != null) return inFlight;
    final future = _fetchWatchlistNumbersImpl();
    _watchlistLoadFuture = future;
    return future.whenComplete(() {
      if (identical(_watchlistLoadFuture, future)) {
        _watchlistLoadFuture = null;
      }
    });
  }

  Future<void> _fetchWatchlistNumbersImpl() async {
    final epoch = _datasetEpoch;
    try {
      if (_appMode == AppMode.standalone) {
        final numbers = await LocalDbService.getWatchlistNumbers();
        if (epoch != _datasetEpoch) return;
        _watchlistNumbers = numbers;
      } else {
        final reports = await _api.getWatchlist();
        if (epoch != _datasetEpoch) return;
        _watchlistNumbers = reports.map((r) => r.reportNumber).toSet();
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> addToWatchlist(List<String> reportNumbers) async {
    if (_appMode == AppMode.standalone) {
      _watchlistNumbers = await LocalDbService.changeWatchlist(
        add: reportNumbers,
      );
    } else {
      await _api.updateWatchlist(reportNumbers, add: true);
      _watchlistNumbers.addAll(reportNumbers);
    }
    notifyListeners();
  }

  Future<void> removeFromWatchlist(List<String> reportNumbers) async {
    if (_appMode == AppMode.standalone) {
      _watchlistNumbers = await LocalDbService.changeWatchlist(
        remove: reportNumbers,
      );
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
  }

  Future<void> startCrawlQueue(List<String> reportNumbers) async {
    // 큐 지정 크롤링은 목록 전체를 다시 보지 않는다 — 모드는 full 로 보낸다(예전 설정의 min 은 레거시 전용이라 없앰)
    await _api.startCrawl(
      crawlMode: 'full',
      queueList: reportNumbers.join('\n'),
    );
  }

  Future<RatingBatchResult> submitRatings(
    List<Report> reports, {
    required int score,
    String cause = '',
  }) async {
    final numbers = reports.map((r) => r.reportNumber).toSet();
    if (numbers.any(_ratingInFlight.contains)) {
      throw StateError('이미 별점을 처리 중인 신고가 있습니다. 완료 후 다시 시도하세요.');
    }
    _ratingInFlight.addAll(numbers);
    final epoch = _datasetEpoch;
    try {
      final result = await RatingService.submit(
        appMode: _appMode,
        selectedReports: reports,
        score: score,
        cause: ratingCauseSupported ? cause : '',
        api: _appMode == AppMode.server ? _api : null,
        isStandaloneDemo: _isStandaloneDemo,
      );

      if (epoch != _datasetEpoch) return result;
      if (result.failureCount == 0 && ratingCauseDraft == cause) {
        ratingCauseDraft = '';
      }
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
    } finally {
      _ratingInFlight.removeAll(numbers);
    }
  }

  Future<void> _refreshSummaryAfterMutation(int epoch) async {
    final pending = _summaryLoadFuture;
    if (pending != null) await pending;
    if (epoch != _datasetEpoch) return;
    if (identical(_summaryLoadFuture, pending)) {
      _summaryLoadFuture = null;
    }
    // A pre-mutation read may have completed after sync/filter refresh began.
    // Read again; unchanged revisions hit the compact cache.
    await fetchSummary();
  }

  Future<void> refreshAll() async {
    if (!isConfigured) return;
    final epoch = _datasetEpoch;
    _errorMessage = null;
    if (_appMode == AppMode.standalone) {
      // sqflite 는 단일 connection 으로 모든 작업을 직렬화하므로
      // 병렬 읽기는 같은 native 큐에서 서로 기다리므로 순차 실행한다.
      await _refreshSummaryAfterMutation(epoch);
      for (final c in _loadedCategories.toList()) {
        await fetchCategoryReports(c);
      }
      if (_duplicateReports.isNotEmpty) await fetchDuplicateReports();
      await fetchWatchlistNumbers();
      // 업데이트 뒤 한 번 훑기: 촬영 시각을 아직 못 읽은 주정차 사진(6개월 이내). 대상이 없으면 바로 끝난다.
      if (!_isStandaloneDemo) {
        unawaited(MaintenanceService.startPhotoBackfill());
      }
    } else {
      await Future.wait([
        _refreshSummaryAfterMutation(epoch),
        ..._loadedCategories.toList().map(fetchCategoryReports),
        fetchWatchlistNumbers(),
        fetchAppConfig(),
      ]);
    }
    if (epoch == _datasetEpoch) bumpStatsRefresh();
  }

  /// Client 모드 하단 표시줄용: 서버의 한 번 훑기 작업 진행. 구서버·오류면 null.
  Future<Map<String, dynamic>?> fetchMaintenanceStatus() =>
      _api.fetchMaintenanceStatus();

  bool matchesFilter(Report report, {ReportFilter? filter}) =>
      _applyFilter([report], filter: filter).isNotEmpty;

  List<Report> applyFilterToReports(List<Report> reports) =>
      _applyFilter(reports);
}
