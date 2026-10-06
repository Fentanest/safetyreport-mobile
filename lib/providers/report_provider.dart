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
import '../services/report_filter_spec.dart';
import '../services/report_policy.dart';
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

String _canonicalStatusLabel(String status) =>
    ReportPolicy.displayStatus(status);

const _recentAnswerStatuses = ReportPolicy.completedStatuses;

typedef _ReportPage = ({List<Report> reports, int total});

class _PageRead {
  final readers = <bool Function()>{};
  late final Future<_ReportPage> future;
  bool cancelled = false;
}

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

  /// 진행 중인 요약·분류·중복 조회 수(SQ-B11). 하나라도 돌면 [isLoading] 이 true 다.
  /// 먼저 끝난 조회가 다른 조회의 스피너를 끄지 않게 플래그 하나 대신 센다.
  int _loadingCount = 0;
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

  /// 지금 연결한 서버의 기능 목록을 받았는가. 서버·모드를 바꾸면 false(알 수 없음)로 돌아가고,
  /// 그동안 기능 게이트 UI 는 숨긴다(SQ-B08 — 예전에는 이전 서버 목록이 남아 지원하지 않는 API 를 불렀다).
  bool _serverCapabilitiesKnown = false;
  bool get serverCapabilitiesKnown => _serverCapabilitiesKnown;

  /// 서버·모드가 바뀔 때 이전 서버의 기능 목록과 진행 중 조회를 버린다.
  void _forgetServerCapabilities() {
    _serverCapabilities = const [];
    _serverCapabilitiesKnown = false;
    _appConfigLoadFuture = null;
  }

  /// 별점 공통 사유를 보낼 수 있는가 — Standalone 은 항상, Client 는 서버가 rating_cause 를 알릴 때만.
  bool get ratingCauseSupported =>
      _appMode == AppMode.standalone ||
      (_serverCapabilitiesKnown &&
          _serverCapabilities.contains('rating_cause'));

  /// 연결된 서버가 "서버의 커뮤니티 계정" API 를 알리는가(Client 모드). 구서버는 false.
  bool get communityAccountSupported =>
      _appMode == AppMode.server &&
      _serverCapabilitiesKnown &&
      _serverCapabilities.contains(ServerContract.communityAccountCapability);

  ReportFilter _filter = const ReportFilter();
  bool _excludeWithdraw = true;
  bool _useRepresentativeRecords = true;

  /// 실제 자료가 바뀌었을 때만 오르는 번호(SQ-P02). 목록·지도·통계·첨부 캐시 범위가 이 값을 본다.
  /// 오르는 때: 로컬 DB 쓰기 revision·data_version·연결이 바뀐 refreshAll, Client 의 refreshAll(변경·사용자 요청 뒤에만 불림),
  /// 받은 변경 알림, [markDataChanged] 를 부르는 명시적 변경. 모드·자료 전환은 [datasetEpoch] 가 따로 맡는다.
  int _dataRevision = 0;
  int get dataRevision => _dataRevision;

  /// 마지막으로 본 로컬 DB 쓰기 표시(연결·쓰기 revision·data_version). 같으면 refreshAll 이 [dataRevision] 을 올리지 않는다.
  String? _lastLocalDataStamp;

  /// 자료가 바뀌었음을 알린다. 보이는 화면은 한 번 다시 읽고, 숨은 탭은 다시 보일 때 읽는다.
  void markDataChanged() {
    _dataRevision++;
    notifyListeners();
  }

  // 통계 탭에 들어왔다는 신호(통계 화면 전용). 자료 변경 신호가 아니다 — 다른 화면은 [dataRevision] 을 본다(SQ-P02).
  // 파일·전국 현황 nonce 는 각 화면 진입 신호다.
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
  bool get isLoading => _loadingCount > 0;
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

  /// 상세 시트의 "같은 조건으로 검색"이 열 분류 탭을 정한다(SQ-P09).
  ///
  /// 분류만 확인한다. 목록은 드릴다운 화면의 페이지 조회가 직접 읽으므로 여기서
  /// 분류 목록(200건)을 미리 읽거나 `_loadedCategories` 에 올리지 않는다
  /// (올리면 이후 모든 refreshAll 이 그 분류를 다시 읽는다).
  /// 분류 정보가 없으면 단건(Standalone) 또는 페이지 조회(Client)로 찾는다.
  Future<String?> categoryForNavigation(Report report) async {
    return findCategory(report) ?? await resolveReportCategory(report);
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
    final statuses = _appMode == AppMode.standalone
        ? options.statuses
        : {..._filterStatuses, ...options.statuses}.toList();
    final laws = _appMode == AppMode.standalone
        ? options.laws
        : {..._filterLaws, ...options.laws}.toList();
    if (_sameList(statuses, _filterStatuses) && _sameList(laws, _filterLaws)) {
      return;
    }
    _filterStatuses = statuses;
    _filterLaws = laws;
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

  bool _contains(String source, String query) =>
      ReportFilterSpec.matchesText(source, query);

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
      if (!ReportFilterSpec.matchesLaw(r.law, f.law)) return false;
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
      // 날짜·시각 범위: 서버·웹과 같은 의미(앞자리 비교, 형식이 맞지 않으면 제외 — ReportFilterSpec)
      for (final range in [
        (r.date, f.reportDateStart, f.reportDateEnd, false),
        (r.occurrenceDate, f.occurDateStart, f.occurDateEnd, false),
        (r.responseDate, f.responseDateStart, f.responseDateEnd, false),
        (r.occurrenceTime, f.occurTimeStart, f.occurTimeEnd, true),
      ]) {
        if (!ReportFilterSpec.inRange(
          range.$1,
          range.$2,
          range.$3,
          time: range.$4,
        )) {
          return false;
        }
      }
      if (f.excludePolice && r.agency.contains('경찰')) return false;
      if (f.onlyPolice && !r.agency.contains('경찰')) return false;
      if (f.pollStatus.isNotEmpty && r.pollStatus.trim() != f.pollStatus) {
        return false;
      }
      return true;
    }).toList();
  }

  void setFilter(ReportFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
    notifyListeners();
  }

  void clearFilter() {
    if (_filter == const ReportFilter()) return;
    _filter = const ReportFilter();
    notifyListeners();
  }

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameSet<T>(Set<T> a, Set<T> b) =>
      identical(a, b) || (a.length == b.length && a.containsAll(b));

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
      final exclude = prefs.getBool('standaloneExcludeWithdraw') ?? true;
      final representative =
          prefs.getBool('standaloneUseRepresentativeRecords') ?? true;
      // 값이 같으면 알리지 않는다(SQ-P07 — 매 refreshAll 마다 전체 화면 재빌드 방지).
      if (exclude == _excludeWithdraw &&
          representative == _useRepresentativeRecords) {
        return;
      }
      _excludeWithdraw = exclude;
      _useRepresentativeRecords = representative;
      notifyListeners();
      return;
    }
    try {
      final cfg = await _api.getAppConfig();
      if (epoch != _datasetEpoch) return;
      final exclude = cfg['exclude_withdraw'] as bool? ?? false;
      final representative = cfg['use_representative_records'] as bool? ?? true;
      final capabilities = [
        for (final c in (cfg['capabilities'] as List? ?? const [])) '$c',
      ];
      if (exclude == _excludeWithdraw &&
          representative == _useRepresentativeRecords &&
          _serverCapabilitiesKnown &&
          _sameList(capabilities, _serverCapabilities)) {
        return;
      }
      _excludeWithdraw = exclude;
      _useRepresentativeRecords = representative;
      _serverCapabilities = capabilities;
      _serverCapabilitiesKnown = true;
      notifyListeners();
    } catch (e) {
      // 기능 목록은 "알 수 없음"으로 남는다(게이트 UI 숨김). 다음 refreshAll 이 다시 묻는다.
      debugPrint('[ReportProvider] 서버 앱 설정 조회 실패: $e');
    }
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

  final _serverPageInFlight = <(int, int, bool, String, int, int), _PageRead>{};

  void _resetDatasetView() {
    _serverPageInFlight.clear();
    _stats = null;
    _trafficReports = [];
    _parkingReports = [];
    _otherReports = [];
    _duplicateReports = [];
    _watchlistNumbers = {};
    _filterStatuses = [];
    _filterLaws = [];
    _loadedCategories.clear();
    _lastLocalDataStamp = null;
    _summaryLoadFuture = null;
    _categoryLoadFutures.clear();
    _duplicateLoadFuture = null;
    _watchlistLoadFuture = null;
  }

  /// 카카오 인증·동의가 풀리면 Client의 백그라운드 서버 연결도 끊는다.
  void onGateBlocked() {
    SyncEngine.stop();
    StandaloneAuthService.stopKeepAlive();
    unawaited(CommunityUploadHooks.cancelBackgroundJobsNow());
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
    _datasetEpoch++;
    _serverPageInFlight.clear();
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
    SyncEngine.stop();
    StandaloneAuthService.invalidateOperations();
    await PermissionService.stopWsService();
    StandaloneAuthService.stopKeepAlive();
    unawaited(BackgroundLoginCheck.cancel());
    unawaited(
      CommunityUploadHooks.cancelBackgroundJobsNow(),
    ); // Client·데모·초기화: 공유 업로드 작업 해제
    final cleanUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    _datasetEpoch++;
    _resetDatasetView();
    _forgetServerCapabilities();
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
    await prefs.setInt(
      'native_config_generation',
      (prefs.getInt('native_config_generation') ?? 0) + 1,
    );
    await prefs.setString(AppPrefsKeys.appMode, AppMode.server.name);
    await prefs.setString(AppPrefsKeys.baseUrl, _baseUrl);
    await prefs.setString(AppPrefsKeys.apiKey, _apiKey);
    await prefs.remove(AppPrefsKeys.standaloneDemoMode);
    await LocalDbService.closeDb();

    _preparedOfficialId = null;
    accountConfigEpoch++;
    notifyListeners();
    if (_gatePassed && isConfigured) await PermissionService.startWsService();
  }

  /// 앱 조립 시 CommunityGate의 서버 계약 검증/바인딩 해제를 연결한다.
  int accountConfigEpoch = 0;
  bool _accountRestartPending = false;
  String? _preparedOfficialId;
  Future<bool> Function(String username)? officialAccountNeedsReset;
  Future<void> Function()? releaseOfficialAccount;

  Future<void> prepareStandaloneAccount(
    String username, {
    Future<bool> Function()? confirmAccountReset,
  }) async {
    SyncEngine.stop();
    StandaloneAuthService.invalidateOperations();
    StandaloneAuthService.stopKeepAlive();
    try {
      final candidate = username.trim().toLowerCase();
      if (candidate.isEmpty) {
        throw ForeignDatabaseException('안전신문고 로그인 계정을 확인할 수 없습니다.');
      }
      final previous =
          _preparedOfficialId ?? _standaloneUsername.trim().toLowerCase();
      final localReset =
          previous.isNotEmpty && previous != candidate && !_isStandaloneDemo;
      final remoteReset =
          await officialAccountNeedsReset?.call(username) ?? false;
      await LocalDbService.prepareOfficialAccountChange(
        resetRequired: localReset || remoteReset,
        releaseBinding: releaseOfficialAccount,
        confirmReset: confirmAccountReset,
      );
      _preparedOfficialId = candidate;
      _accountRestartPending =
          _accountRestartPending ||
          await LocalDbService.getMeta(LocalDbService.officialRestartKey) ==
              'true';
    } catch (_) {
      // 로그인은 성공했지만 설정을 적용하지 못했다. 새 비밀번호/토큰을 옛 ID와 함께 쓰지 않는다.
      await StandaloneAuthService.clearToken();
      rethrow;
    }
  }

  Future<void> setStandaloneConfig(
    String username, {
    required String phoneNumber,
    bool isDemoMode = false,
    Future<bool> Function()? confirmAccountReset,
  }) async {
    SyncEngine.stop();
    StandaloneAuthService.invalidateOperations();
    await PermissionService.stopWsService();
    if (!isDemoMode) {
      await prepareStandaloneAccount(
        username,
        confirmAccountReset: confirmAccountReset,
      );
    }
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
      }
    }
    _gatePassed = false;
    _datasetEpoch++;
    _resetDatasetView();
    _forgetServerCapabilities();
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
    await prefs.setInt(
      'native_config_generation',
      (prefs.getInt('native_config_generation') ?? 0) + 1,
    );
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

    if (!isDemoMode && _accountRestartPending) {
      await LocalDbService.setMeta(LocalDbService.officialRestartKey, 'true');
      _accountRestartPending = false;
    }
    _preparedOfficialId = null;
    accountConfigEpoch++;
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
    SyncEngine.stop();
    StandaloneAuthService.invalidateOperations();
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
    await prefs.setInt(
      'native_config_generation',
      (prefs.getInt('native_config_generation') ?? 0) + 1,
    );
    await prefs.remove(AppPrefsKeys.appMode);
    await prefs.remove(AppPrefsKeys.baseUrl);
    await prefs.remove(AppPrefsKeys.apiKey);
    await prefs.remove(AppPrefsKeys.standaloneKakaoRestApiKey);
    await prefs.remove(AppPrefsKeys.standaloneUsername);
    await prefs.remove(AppPrefsKeys.standalonePhoneNumber);
    await prefs.remove(AppPrefsKeys.standaloneDemoMode);
    await StandaloneAuthService.clearToken();
    // 실제 모드 변경: Standalone 커뮤니티 세션·대기 로그인을 지운다(M05). 서버의 커뮤니티 계정은 건드리지 않는다.
    _forgetServerCapabilities();
    try {
      await CommunityAuthService.instance.clearForModeChange();
    } catch (_) {}
    await LocalDbService.closeDb();

    _preparedOfficialId = null;
    accountConfigEpoch++;
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

  /// 조회 하나를 시작한다. 다른 조회가 이미 돌고 있으면 [isLoading] 은 그대로라 알리지 않는다.
  void _beginLoad({bool clearError = false}) {
    final changed = _loadingCount == 0 || (clearError && _errorMessage != null);
    _loadingCount++;
    if (clearError) _errorMessage = null;
    if (changed) notifyListeners();
  }

  /// 조회 하나를 끝낸다. 자료셋이 바뀐 뒤 끝난 조회도 개수는 줄인다(스피너가 남지 않게).
  /// [notify] 가 false 면(이전 자료셋의 결과) 결과 반영 없이 개수만 맞춘다.
  void _endLoad({required bool notify}) {
    if (_loadingCount > 0) _loadingCount--;
    if (notify || _loadingCount == 0) notifyListeners();
  }

  Future<void> _fetchSummaryImpl() async {
    final epoch = _datasetEpoch;
    _beginLoad(clearError: true);
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
      _endLoad(notify: epoch == _datasetEpoch);
    }
  }

  /// 카테고리 별 fetch 공통 경로 — 모드 분기와 결과 저장만 다르고 형태는 동일.
  /// `traffic` / `parking` / `other` 만 정식 카테고리. 알 수 없는 값은 무시.
  Future<({List<Report> reports, int total})> readServerPage(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) {
    final epoch = _datasetEpoch;
    // 자료가 바뀐 뒤의 요청은 바뀌기 전에 시작한 요청을 공유하지 않는다(SQ-P02: 통계 탭 신호가 아닌 dataRevision).
    final key = (
      epoch,
      _dataRevision,
      _useRepresentativeRecords,
      category,
      offset,
      limit,
    );
    final reader = isCancelled ?? () => false;
    var owner = _serverPageInFlight[key];
    if (owner == null || owner.cancelled) {
      final next = _PageRead();
      next.readers.add(reader);
      bool cancelled() {
        if (epoch != _datasetEpoch || next.readers.every((r) => r())) {
          next.cancelled = true;
        }
        return next.cancelled;
      }

      next.future =
          _readServerPageOwned(
            category,
            offset: offset,
            limit: limit,
            isCancelled: cancelled,
          ).whenComplete(() {
            if (identical(_serverPageInFlight[key], next)) {
              _serverPageInFlight.remove(key);
            }
          });
      _serverPageInFlight[key] = next;
      owner = next;
    } else {
      owner.readers.add(reader);
    }
    final pending = owner;
    return pending.future.whenComplete(() => pending.readers.remove(reader));
  }

  Future<({List<Report> reports, int total})> _readServerPageOwned(
    String category, {
    int offset = 0,
    int limit = 200,
    bool Function()? isCancelled,
  }) async {
    final epoch = _datasetEpoch;
    final page = await _api.getReportsPage(
      category,
      offset: offset,
      limit: limit,
      dedupe: _useRepresentativeRecords ? 'canonical' : 'raw',
      isCancelled: isCancelled,
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
    _beginLoad();
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
      _endLoad(notify: epoch == _datasetEpoch);
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
    _beginLoad();
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
      _endLoad(notify: epoch == _datasetEpoch);
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
      final Set<String> numbers;
      if (_appMode == AppMode.standalone) {
        numbers = await LocalDbService.getWatchlistNumbers();
      } else {
        final reports = await _api.getWatchlist();
        numbers = reports.map((r) => r.reportNumber).toSet();
      }
      if (epoch != _datasetEpoch) return;
      // 같은 목록이면 알리지 않는다(SQ-P07).
      if (_sameSet(numbers, _watchlistNumbers)) return;
      _watchlistNumbers = numbers;
      notifyListeners();
    } catch (_) {}
  }

  /// 감시 목록 추가·해제(SQ-B10). 요청 중 모드·서버·자료셋이 바뀌면([datasetEpoch]) 결과를 새 자료셋에 쓰지 않는다.
  /// 같은 Set 을 제자리에서 바꾸지 않고 새 Set 을 넣어, 이전 값을 들고 비교하는 화면이 변경을 알아채게 한다.
  Future<void> addToWatchlist(List<String> reportNumbers) =>
      _changeWatchlist(reportNumbers, add: true);

  Future<void> removeFromWatchlist(List<String> reportNumbers) =>
      _changeWatchlist(reportNumbers, add: false);

  Future<void> _changeWatchlist(
    List<String> reportNumbers, {
    required bool add,
  }) async {
    final epoch = _datasetEpoch;
    final Set<String> next;
    if (_appMode == AppMode.standalone) {
      next = await LocalDbService.changeWatchlist(
        add: add ? reportNumbers : const [],
        remove: add ? const [] : reportNumbers,
      );
      if (epoch != _datasetEpoch) return;
    } else {
      await _api.updateWatchlist(reportNumbers, add: add);
      if (epoch != _datasetEpoch) return;
      next = add
          ? {..._watchlistNumbers, ...reportNumbers}
          : ({..._watchlistNumbers}..removeAll(reportNumbers));
    }
    _watchlistNumbers = next;
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
    if (epoch != _datasetEpoch) return;
    // SQ-P02: 자료가 실제로 바뀐 때만 화면들에 다시 읽으라고 알린다.
    // Standalone 은 DB 쓰기 표시(연결·쓰기 revision·data_version)로 판정한다 — 앱 복귀처럼 대기열이 비어 아무것도
    // 쓰지 않은 refreshAll 은 목록·지도·통계를 다시 읽게 하지 않는다. 표시를 읽지 못하면 바뀐 것으로 본다.
    // Client 의 refreshAll 은 변경(크롤링 완료·별점·수정·DB 가져오기)이나 사용자 요청 뒤에만 불리므로 바뀐 것으로 본다.
    if (_appMode == AppMode.standalone) {
      String? stamp;
      try {
        stamp = await LocalDbService.readDataStamp();
      } catch (_) {
        stamp = null;
      }
      if (epoch != _datasetEpoch) return;
      if (stamp != null && stamp == _lastLocalDataStamp) return;
      _lastLocalDataStamp = stamp;
    }
    markDataChanged();
  }

  /// Client 모드 하단 표시줄용: 서버의 한 번 훑기 작업 진행. 구서버·오류면 null.
  Future<Map<String, dynamic>?> fetchMaintenanceStatus() =>
      _api.fetchMaintenanceStatus();

  bool matchesFilter(Report report, {ReportFilter? filter}) =>
      _applyFilter([report], filter: filter).isNotEmpty;

  List<Report> applyFilterToReports(List<Report> reports) =>
      _applyFilter(reports);
}
