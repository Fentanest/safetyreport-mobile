import '../services/performance_trace.dart';
import '../services/map_presentation.dart';
import '../widgets/local_paged_report_list.dart';
import 'dart:async' show TimeoutException, Timer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_mode.dart';
import '../models/report.dart';
import '../models/report_map.dart';
import '../providers/report_provider.dart';
import '../server_palette.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/permission_service.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/report_list_card.dart';
import '../widgets/status_badge.dart';
import '../widgets/community_upload_panel.dart';
import '../widgets/report_map_overlays.dart';
import 'report_list_screen.dart';
import 'settings_screen.dart';
import '../theme/sr_colors.dart';
import '../theme/sr_tokens.dart';
import '../widgets/sr_snack_bar.dart';
import '../services/support_links.dart';

const double _kMapMarkerWidth = 100;
const double _kMapMarkerHeight = 98;
const double _kMapMarkerLabelMaxWidth = 92;
const String _kOsmCopyrightUrl = 'https://www.openstreetmap.org/copyright';

/// 지도 화면이 쓰는 위치 기능. 권한 요청 시점(SQ-U11)을 테스트로 고정하려고 주입할 수 있게 둔다.
class ReportMapLocationGateway {
  const ReportMapLocationGateway();

  Future<bool> isPermissionGranted() =>
      PermissionService.isLocationPermissionGranted();

  Future<LocationPermission> requestPermission() =>
      PermissionService.requestLocationPermission();

  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  Future<Position> getCurrentPosition() => Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 12),
    ),
  );

  Future<Position?> getLastKnownPosition() => Geolocator.getLastKnownPosition();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  Future<bool> openAppSettings() =>
      PermissionService.openAppPermissionSettings();
}

/// 지도 집계 조회. 기본은 모드에 따라 로컬 DB 또는 서버 API(`_ReportMapScreenState._loadMap`).
typedef ReportMapPayloadLoader =
    Future<ReportMapPayload> Function({
      List<double>? bounds,
      required double zoom,
      String? year,
      required String category,
      required String pinBasis,
    });

class ReportMapScreen extends StatefulWidget {
  final String initialYear;
  final String initialCategory;

  /// 핀 기준 초기값. 분류 선택과 같이 화면 상태로 유지한다.
  final String initialPinBasis;
  final ReportMapLocationGateway locationGateway;

  /// 테스트 전용: 지도 집계 조회를 바꿔 끼운다.
  @visibleForTesting
  final ReportMapPayloadLoader? payloadLoader;

  /// 테스트 전용: 타일을 네트워크 없이 그린다. null 이면 flutter_map 기본(네트워크) 타일.
  @visibleForTesting
  final TileProvider? tileProvider;

  const ReportMapScreen({
    super.key,
    this.initialYear = 'all',
    this.initialCategory = 'all',
    this.initialPinBasis = 'coords',
    this.locationGateway = const ReportMapLocationGateway(),
    this.payloadLoader,
    this.tileProvider,
  });

  @override
  State<ReportMapScreen> createState() => _ReportMapScreenState();
}

class _ReportMapScreenState extends State<ReportMapScreen>
    with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  ReportMapPayload? _payload;
  int _loadSeq = 0;
  Timer? _viewportTimer;
  List<double>? _viewport;
  double _viewportZoom = 7;
  String? _datasetScope;
  bool _loading = true;
  bool _locating = false;
  String? _error;
  String? _locationError;
  LatLng? _currentLocation;
  String _selectedYear = 'all';
  String _selectedCategory = 'all';

  /// 핀 기준. 'coords'(위도·경도) 또는 'address'(주소). 분류 선택과 같이 화면 상태로 유지한다.
  String _selectedPinBasis = 'coords';

  /// 서버가 주소 기준을 지원하지 않을 때의 안내(토글을 다시 누르면 지운다).
  String? _pinBasisNotice;

  // SQ-P05: 마커는 조회 결과(_payload)가 바뀔 때만 다시 만든다. marker_cluster 는 마커 리스트를
  // 동일성으로 비교하므로, 매 build 마다 새 리스트를 주면 줌 단계 전체 클러스터를 다시 계산한다.
  _MapMarkerCache? _markerCache;

  /// 권한 설명 창을 띄우는 중(연속 탭으로 창이 두 번 뜨지 않게).
  bool _promptingLocation = false;

  ReportMapLocationGateway get _location => widget.locationGateway;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedYear = widget.initialYear;
    _selectedCategory = widget.initialCategory;
    _selectedPinBasis = widget.initialPinBasis == 'address'
        ? 'address'
        : 'coords';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMap();
      // SQ-U11: 진입 시에는 권한을 요청하지 않는다. 이미 허용된 경우에만 현재 위치를 보인다.
      // 요청은 "현재 위치" 버튼을 눌렀을 때 설명을 먼저 보인 뒤 한다.
      _loadCurrentLocation(requestPermission: false, moveCamera: true);
    });
  }

  /// 자료가 바뀌었는데 화면이 가려져 있던 동안(TickerMode 꺼짐) 미뤄 둔 다시 조회(SQ-P02).
  bool _stale = false;

  /// Provider 중 이 화면이 실제로 쓰는 값만 구독한다(SQ-P05). 값이 바뀌면 처음부터 다시 조회한다.
  /// 자료 변경은 dataRevision 으로만 본다(통계 탭 진입은 자료 변경이 아니다 — SQ-P02).
  /// 다른 화면에 가려져 있으면 표시만 해 두고 다시 보일 때 한 번 읽는다.
  void _watchDatasetScope(BuildContext context) {
    final visible = TickerMode.valuesOf(context).enabled;
    final scope = context.select<ReportProvider, String>(
      (p) =>
          '${p.datasetEpoch}:${p.dataRevision}:${p.excludeWithdraw}:${p.useRepresentativeRecords}',
    );
    if (_datasetScope != null && _datasetScope != scope) {
      _loadSeq++;
      _payload = null;
      _loading = true;
      _stale = true;
    }
    _datasetScope = scope;
    if (_stale && visible) {
      _stale = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadMap();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _viewportTimer?.cancel();
    _loadSeq++;
    _mapController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _currentLocation == null) {
      _loadCurrentLocation(requestPermission: false);
    }
  }

  Future<void> _loadMap({bool silent = false}) async {
    final seq = ++_loadSeq;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final provider = context.read<ReportProvider>();
    final epoch = provider.datasetEpoch;
    try {
      ReportMapPayload payload;
      final loader = widget.payloadLoader;
      if (loader != null) {
        payload = await loader(
          bounds: _viewport,
          zoom: _viewportZoom,
          year: _selectedYear == 'all' ? null : _selectedYear,
          category: _selectedCategory,
          pinBasis: _selectedPinBasis,
        );
      } else if (provider.appMode == AppMode.standalone) {
        payload = ReportMapPayload.fromJson(
          await LocalDbService.computeReportMapStats(
            bounds: _viewport,
            zoom: _viewportZoom,
            isCancelled: () =>
                !mounted || seq != _loadSeq || epoch != provider.datasetEpoch,
            year: _selectedYear == 'all' ? null : _selectedYear,
            category: _selectedCategory,
            excludeWithdraw: provider.excludeWithdraw,
            useRepresentativeRecords: provider.useRepresentativeRecords,
            pinBasis: _selectedPinBasis,
          ),
        );
      } else {
        final api = ApiService(
          baseUrl: provider.baseUrl,
          apiKey: provider.apiKey,
        );
        payload = await api.getReportMapStats(
          bounds: _viewport,
          zoom: _viewportZoom,
          dedupe: provider.useRepresentativeRecords ? 'canonical' : 'raw',
          year: _selectedYear == 'all' ? null : _selectedYear,
          category: _selectedCategory,
          pinBasis: _selectedPinBasis,
        );
      }

      if (!mounted || seq != _loadSeq || epoch != provider.datasetEpoch) return;
      // 구 서버는 pin_basis 를 모르고 위도·경도 기준으로 답한다. 받은 기준으로 토글을 되돌려
      // 화면 표시와 실제 핀이 어긋나지 않게 한다(Sol 1차 M4).
      final unsupported =
          _selectedPinBasis == 'address' && payload.meta.pinBasis != 'address';
      setState(() {
        _payload = payload;
        _loading = false;
        _error = null;
        if (unsupported) {
          _selectedPinBasis = 'coords';
          _pinBasisNotice = '서버를 업데이트해야 주소 기준을 쓸 수 있습니다.';
        }
      });
    } on QueryCancelled {
      return;
    } catch (exc) {
      if (!mounted || seq != _loadSeq || epoch != provider.datasetEpoch) return;
      setState(() {
        _loading = false;
        _error = '$exc';
      });
    }
  }

  Future<void> _loadCurrentLocation({
    required bool requestPermission,
    bool moveCamera = false,
    bool showMessages = false,
  }) async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _locationError = null;
    });

    try {
      final hasPermission = await _ensureLocationPermission(
        requestPermission: requestPermission,
        showMessages: showMessages,
      );
      if (!hasPermission) return;

      final serviceEnabled = await _location.isServiceEnabled();
      if (!serviceEnabled) {
        _setLocationError('기기 위치 서비스가 꺼져 있어 현재 위치를 표시할 수 없습니다.');
        if (showMessages) {
          _showLocationSnackBar(
            '기기 위치 서비스가 꺼져 있습니다.',
            action: SnackBarAction(
              label: '설정',
              onPressed: _location.openLocationSettings,
            ),
          );
        }
        return;
      }

      final position = await _resolveCurrentPosition();
      if (!mounted) return;
      final nextLocation = LatLng(position.latitude, position.longitude);
      setState(() {
        _currentLocation = nextLocation;
        _locationError = null;
      });
      if (moveCamera) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _moveMapToCurrentLocation();
        });
      }
    } on TimeoutException {
      _setLocationError('현재 위치를 가져오는 데 시간이 오래 걸립니다.');
      if (showMessages) {
        _showLocationSnackBar('현재 위치를 가져오지 못했습니다. 잠시 후 다시 시도해 주세요.');
      }
    } catch (_) {
      _setLocationError('현재 위치를 가져오지 못했습니다.');
      if (showMessages) {
        _showLocationSnackBar('현재 위치를 가져오지 못했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() => _locating = false);
      }
    }
  }

  Future<bool> _ensureLocationPermission({
    required bool requestPermission,
    required bool showMessages,
  }) async {
    if (await _location.isPermissionGranted()) return true;
    // 조용한 확인(화면 진입·앱 복귀)에서는 권한이 없어도 오류로 표시하지 않는다.
    // 사용자가 아직 버튼을 누르지 않았으므로 "위치 꺼짐" 아이콘 대신 기본 아이콘을 둔다.
    if (!requestPermission) return false;

    final permission = await _location.requestPermission();
    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      return true;
    }

    final permanentlyDenied = permission == LocationPermission.deniedForever;
    _setLocationError('위치 권한이 없어 현재 위치를 표시할 수 없습니다.');
    if (showMessages || permanentlyDenied) {
      _showLocationSnackBar(
        permanentlyDenied ? '위치 권한이 차단되어 있습니다.' : '위치 권한이 허용되지 않았습니다.',
        action: permanentlyDenied
            ? SnackBarAction(label: '설정', onPressed: _location.openAppSettings)
            : null,
      );
    }
    return false;
  }

  /// "현재 위치" 버튼. 권한이 없으면 앱 안 설명을 먼저 보이고, 사용자가 허용을 고를 때만 시스템 권한 창을 띄운다.
  Future<void> _onCurrentLocationPressed() async {
    if (_locating || _promptingLocation) return;
    _promptingLocation = true;
    try {
      if (!await _location.isPermissionGranted()) {
        if (!mounted) return;
        final proceed = await _showLocationRationale();
        if (!mounted || proceed != true) return;
      }
    } finally {
      _promptingLocation = false;
    }
    await _loadCurrentLocation(
      requestPermission: true,
      moveCamera: true,
      showMessages: true,
    );
  }

  Future<bool?> _showLocationRationale() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('위치 권한 안내'),
        content: const Text('지도에서 내 위치로 이동하려면 위치 권한이 필요합니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('허용'),
          ),
        ],
      ),
    );
  }

  Future<Position> _resolveCurrentPosition() async {
    try {
      return await _location.getCurrentPosition();
    } catch (_) {
      final lastKnown = await _location.getLastKnownPosition();
      if (lastKnown != null) return lastKnown;
      rethrow;
    }
  }

  void _setLocationError(String message) {
    if (!mounted) return;
    setState(() => _locationError = message);
  }

  void _showLocationSnackBar(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    showSrSnack(context, message, action: action);
  }

  void _moveMapToCurrentLocation() {
    final location = _currentLocation;
    if (location == null) return;
    try {
      final currentZoom = _mapController.camera.zoom;
      _mapController.move(location, math.max(currentZoom, 15));
    } catch (_) {
      // MapController may not be attached yet during the first frame.
    }
  }

  List<String> get _availableYears {
    final years = _payload?.meta.availableYears ?? const <String>[];
    return ['all', ...years.where((year) => year != 'all')];
  }

  @override
  Widget build(BuildContext context) =>
      PerformanceTrace.sync('map.screen_build', () => _buildMeasured(context));

  Widget _buildMeasured(BuildContext context) {
    _watchDatasetScope(context);
    final cs = Theme.of(context).colorScheme;
    final payload = _payload;
    final markerCache = _markersFor(payload);

    return Scaffold(
      appBar: AppBar(
        title: const Text('신고 지도'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt_outlined),
            tooltip: '공식 좌표 없는 신고 보기',
            onPressed: _showMissingAddressSheet,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
            onPressed: () => _loadMap(),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '설정',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ).then((_) => _loadMap()),
          ),
        ],
      ),
      body: _loading && payload == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildFilterBar(cs),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _buildErrorCard(_error!),
                  ),
                if (payload != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _buildMetaSummary(payload.meta),
                  ),
                // 커뮤니티 공유 업로드 (접이식 카드 — 지도와 겹치지 않게 필터 바 아래).
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: CommunityUploadPanelHost(),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child:
                        markerCache.validPoints.isEmpty &&
                            _currentLocation == null
                        ? _buildEmptyState()
                        : _buildMap(markerCache),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildFilterBar(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.35)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.filter_alt_outlined, size: 18),
              const SizedBox(width: 6),
              const Text(
                '지도 필터',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              DropdownButton<String>(
                value: _availableYears.contains(_selectedYear)
                    ? _selectedYear
                    : 'all',
                underline: const SizedBox.shrink(),
                items: _availableYears
                    .map(
                      (year) => DropdownMenuItem<String>(
                        value: year,
                        child: Text(year == 'all' ? '전체 연도' : year),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _selectedYear = value);
                  _loadMap();
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _categoryChip('all', '전체'),
              _categoryChip('traffic', '교통'),
              _categoryChip('parking', '주정차'),
              _categoryChip('other', '기타'),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '핀 기준',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              _pinBasisChip('coords', '위도·경도'),
              _pinBasisChip('address', '주소'),
            ],
          ),
          if (_pinBasisNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _pinBasisNotice!,
                key: const ValueKey('map-pin-basis-notice'),
                style: TextStyle(fontSize: 12, height: 1.45, color: cs.error),
              ),
            ),
          if (_selectedPinBasis == 'address')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '같은 주소의 신고를 한 핀으로 묶고, 그 주소에서 가장 많이 신고된 공식 좌표에 표시합니다.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<ReportMapMissingPayload> _loadMissingAddressGroups({
    int page = 0,
  }) async {
    final provider = context.read<ReportProvider>();
    if (provider.appMode == AppMode.standalone) {
      return ReportMapMissingPayload.fromJson(
        await LocalDbService.computeReportMapMissingGroups(
          page: page,
          year: _selectedYear == 'all' ? null : _selectedYear,
          category: _selectedCategory,
          excludeWithdraw: provider.excludeWithdraw,
          useRepresentativeRecords: provider.useRepresentativeRecords,
          pinBasis: _selectedPinBasis,
        ),
      );
    }

    final api = ApiService(baseUrl: provider.baseUrl, apiKey: provider.apiKey);
    return api.getReportMapMissingGroups(
      year: _selectedYear == 'all' ? null : _selectedYear,
      category: _selectedCategory,
      pinBasis: _selectedPinBasis,
    );
  }

  void _showMissingAddressSheet() {
    var page = 0;
    var future = _loadMissingAddressGroups();
    final local = context.read<ReportProvider>().appMode == AppMode.standalone;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .8,
            child: FutureBuilder<ReportMapMissingPayload>(
              future: future,
              builder: (ctx, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('${snapshot.error}'));
                }
                final payload = snapshot.data!;
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: payload.groups.length + 1,
                  itemBuilder: (ctx, index) {
                    if (index > 0) {
                      return _buildMissingAddressGroupCard(
                        payload.groups[index - 1],
                      );
                    }
                    return Column(
                      children: [
                        const Text('공식 좌표 없는 신고 목록'),
                        Text(
                          '주소 ${payload.groupCount}곳 · 신고 ${payload.reportCount}건',
                        ),
                        if (local)
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text('${page + 1}페이지 · 주소당 최근 10건 미리보기'),
                              IconButton(
                                tooltip: '이전 페이지',
                                icon: const Icon(Icons.chevron_left),
                                onPressed: page == 0
                                    ? null
                                    : () => setSheet(() {
                                        page--;
                                        future = _loadMissingAddressGroups(
                                          page: page,
                                        );
                                      }),
                              ),
                              IconButton(
                                tooltip: '다음 페이지',
                                icon: const Icon(Icons.chevron_right),
                                onPressed:
                                    (page + 1) * 100 >= payload.groupCount
                                    ? null
                                    : () => setSheet(() {
                                        page++;
                                        future = _loadMissingAddressGroups(
                                          page: page,
                                        );
                                      }),
                              ),
                            ],
                          ),
                        if (payload.groups.isEmpty)
                          const Text('현재 조건에서 공식 좌표 없는 신고가 없습니다.'),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMissingAddressGroupCard(ReportMapMissingGroup group) {
    final title = group.address.trim().isNotEmpty
        ? group.address.trim()
        : group.normalizedAddress.trim();
    final region = group.region.trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Text(
          title.isNotEmpty ? title : '주소 정보 없음',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        subtitle: region.isNotEmpty ? Text(region) : null,
        // 대비 보정 배지(SQ-U13): 원색 글자 + 옅은 배경은 AA 미달이었다.
        trailing: StatusBadge(
          label: '${group.reportCount}건',
          color: serverSupplementColor,
          fontSize: 12,
        ),
        children: [
          ...group.reports.map(_buildMissingReportCard),
          if (context.read<ReportProvider>().appMode == AppMode.standalone)
            TextButton(
              child: const Text('이 주소의 전체 신고 보기'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(title)),
                    body: LocalPagedReportList(
                      scope: 'missing',
                      missingAddress: group.normalizedAddress,
                      category: _selectedCategory,
                      answerYear: _selectedYear,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMissingReportCard(Report report) {
    return ReportListCard(
      report: report,
      selectionMode: false,
      isSelected: false,
      onTap: () => showReportDetailSheet(context, report),
      onLongPress: () {},
      metaItems: [
        ReportCardMetaItem(
          icon: Icons.calendar_today,
          text: report.date.isNotEmpty ? '신고: ${report.date}' : '',
        ),
        ReportCardMetaItem(
          icon: Icons.event_available,
          text: report.responseDate.isNotEmpty
              ? '답변: ${report.responseDate}'
              : '',
        ),
        ReportCardMetaItem(icon: Icons.business, text: report.agency),
        ReportCardMetaItem(icon: Icons.person_outline, text: report.manager),
        ReportCardMetaItem(
          icon: Icons.location_on_outlined,
          text: report.location,
        ),
        ReportCardMetaItem(
          icon: Icons.monetization_on_outlined,
          text: report.fineInfo,
        ),
      ],
    );
  }

  Widget _categoryChip(String value, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _selectedCategory == value,
      onSelected: (selected) {
        if (!selected) return;
        setState(() => _selectedCategory = value);
        _loadMap();
      },
    );
  }

  Widget _pinBasisChip(String value, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _selectedPinBasis == value,
      onSelected: (selected) {
        if (!selected) return;
        setState(() {
          _selectedPinBasis = value;
          _pinBasisNotice = null;
        });
        _loadMap();
      },
    );
  }

  StatusTone _tone(Color base) {
    final theme = Theme.of(context);
    return StatusTone.of(
      base,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    );
  }

  Widget _buildErrorCard(String message) {
    return Card(
      color: _tone(serverRejectColor).background,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: _tone(serverRejectColor).foreground,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 13, height: 1.45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaSummary(ReportMapMeta meta) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(SrRadius.lg),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          _summaryCell('전체', meta.totalReports, serverProcessingColor),
          _summaryDivider(theme.colorScheme.outlineVariant),
          _summaryCell('좌표화', meta.geocodedReports, serverAcceptColor),
          _summaryDivider(theme.colorScheme.outlineVariant),
          _summaryCell('좌표 없음', meta.missingReports, serverSupplementColor),
          _summaryDivider(theme.colorScheme.outlineVariant),
          _summaryCell('처리기관', meta.agencyCount, changeNewColor, suffix: '곳'),
        ],
      ),
    );
  }

  Widget _summaryDivider(Color color) {
    return Container(
      width: 1,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: color.withValues(alpha: 0.7),
    );
  }

  Widget _summaryCell(
    String label,
    int value,
    Color color, {
    String suffix = '건',
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: SrFontSize.caption,
                  fontWeight: FontWeight.w700,
                  color: _tone(color).foreground,
                ),
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$value$suffix',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: _tone(color).foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    const message = '표시할 공식 좌표가 없습니다.\n신고를 동기화한 뒤 다시 확인해 주세요.';
    return Card(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                size: 48,
                color: context.sr.textDisabled,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 조회 결과가 같으면(동일 객체) 이전 마커 리스트를 그대로 돌려준다.
  _MapMarkerCache _markersFor(ReportMapPayload? payload) {
    final cached = _markerCache;
    if (cached != null && identical(cached.payload, payload)) return cached;
    final next = PerformanceTrace.sync('map.marker_creation', () {
      final validPoints = (payload?.points ?? const <ReportMapPoint>[])
          .where((point) => point.hasValidCoordinates)
          .toList(growable: false);
      final visiblePoints = visibleMapCells(validPoints, _viewport);
      final lookup = <Marker, ReportMapPoint>{};
      final markers = visiblePoints
          .map((point) {
            final marker = Marker(
              point: LatLng(point.lat, point.lng),
              width: _kMapMarkerWidth,
              height: _kMapMarkerHeight,
              child: _MapPointMarker(point: point),
            );
            lookup[marker] = point;
            return marker;
          })
          .toList(growable: false);
      return _MapMarkerCache(
        payload: payload,
        validPoints: validPoints,
        markers: markers,
        lookup: lookup,
        center: _computeCenter(visiblePoints),
        zoom: _suggestZoom(visiblePoints),
      );
    });
    _markerCache = next;
    return next;
  }

  Widget _buildMap(_MapMarkerCache cache) {
    final currentLocation = _currentLocation;
    final center = currentLocation ?? cache.center;
    final zoom = currentLocation != null ? 15.0 : cache.zoom;
    final markerLookup = cache.lookup;
    final markers = cache.markers;

    return ClipRRect(
      borderRadius: BorderRadius.circular(SrRadius.xl),
      child: Stack(
        children: [
          FlutterMap(
            key: ValueKey(
              '${_selectedYear}_${_selectedCategory}_$_selectedPinBasis',
            ),
            mapController: _mapController,
            options: MapOptions(
              onPositionChanged: (camera, hasGesture) {
                if (!hasGesture) return;
                final bounds = camera.visibleBounds;
                _viewport = [
                  bounds.south,
                  bounds.west,
                  bounds.north,
                  bounds.east,
                ];
                _viewportZoom = camera.zoom;
                _viewportTimer?.cancel();
                _viewportTimer = Timer(const Duration(milliseconds: 250), () {
                  if (mounted) _loadMap(silent: true);
                });
              },
              initialCenter: center,
              initialZoom: zoom,
              maxZoom: 18,
              minZoom: 4,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.fentanest.mysafetyreport',
                tileProvider: widget.tileProvider,
              ),
              if (markers.isNotEmpty)
                MarkerClusterLayerWidget(
                  options: MarkerClusterLayerOptions(
                    markers: markers,
                    maxClusterRadius: 54,
                    size: const Size(_kMapMarkerWidth, _kMapMarkerHeight),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(48),
                    maxZoom: 17,
                    disableClusteringAtZoom: 16,
                    zoomToBoundsOnClick: true,
                    centerMarkerOnClick: false,
                    showPolygon: false,
                    spiderfyCluster: true,
                    builder: (context, clusterMarkers) => _ClusterMarkerWidget(
                      totalCount: clusterMarkers.fold<int>(
                        0,
                        (sum, marker) =>
                            sum + (markerLookup[marker]?.total ?? 0),
                      ),
                      regionLabel: dominantMapRegionLabel(
                        clusterMarkers
                            .map((marker) => markerLookup[marker])
                            .whereType<ReportMapPoint>(),
                      ),
                    ),
                    onMarkerTap: (marker) {
                      final point = markerLookup[marker];
                      if (point != null) {
                        _showPointBottomSheet(point);
                      }
                    },
                    onClusterTap: (cluster) {
                      _showClusterBottomSheet(
                        cluster.markers
                            .map((marker) => markerLookup[marker])
                            .whereType<ReportMapPoint>()
                            .toList(),
                      );
                    },
                  ),
                ),
              if (currentLocation != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: currentLocation,
                      width: 56,
                      height: 56,
                      child: const _CurrentLocationMarker(),
                    ),
                  ],
                ),
            ],
          ),
          // SQ-U24: 마커 색(과태료율) 범례.
          const Positioned(left: 8, top: 8, child: MapFineRateLegend()),
          // 커뮤니티 지도 바로가기(오른쪽 위). 좁은 화면은 범례와 겹치지 않게 아이콘만.
          Positioned(
            right: 8,
            top: 8,
            child: MapCommunityMapButton(
              compact: MediaQuery.sizeOf(context).width < 360,
              onPressed: _openCommunityMap,
            ),
          ),
          // SQ-U10: OSM 타일 사용 조건(ODbL·OSMF 타일 정책)인 출처 표기.
          // 오른쪽 아래는 현재 위치 버튼 자리라 그만큼 비우고 왼쪽 아래에 둔다.
          Positioned(
            left: 8,
            right: 64,
            bottom: 8,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: MapOsmAttribution(
                onTap: () => launchUrl(
                  Uri.parse(_kOsmCopyrightUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: _buildCurrentLocationButton(),
          ),
        ],
      ),
    );
  }

  /// 커뮤니티 지도는 폰의 기본 브라우저 앱으로 연다(앱 안 웹뷰·Custom Tab 금지). 커뮤니티 지도의
  /// 카카오 로그인·세션이 앱 안 브라우저에서는 끊기거나 섞일 수 있다(2026-10-05 사용자 지시).
  Future<void> _openCommunityMap() async {
    var ok = false;
    try {
      ok = await launchUrl(
        Uri.parse(SupportLinks.communityMap),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('브라우저를 열지 못했습니다. 다시 시도해 주세요.')),
      );
    }
  }

  Widget _buildCurrentLocationButton() {
    final locationError = _locationError;
    final icon = _locating
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            locationError != null ? Icons.location_disabled : Icons.my_location,
          );
    return FloatingActionButton.small(
      heroTag: 'reportMapCurrentLocation',
      tooltip: locationError ?? '현재 위치',
      onPressed: _locating ? null : _onCurrentLocationPressed,
      child: icon,
    );
  }

  LatLng _computeCenter(List<ReportMapPoint> points) {
    if (points.isEmpty) return const LatLng(36.4, 127.9);
    final latSum = points.fold<double>(0, (sum, item) => sum + item.lat);
    final lngSum = points.fold<double>(0, (sum, item) => sum + item.lng);
    return LatLng(latSum / points.length, lngSum / points.length);
  }

  double _suggestZoom(List<ReportMapPoint> points) {
    if (points.length <= 1) return 14;
    final lats = points.map((point) => point.lat).toList()..sort();
    final lngs = points.map((point) => point.lng).toList()..sort();
    final latSpan = (lats.last - lats.first).abs();
    final lngSpan = (lngs.last - lngs.first).abs();
    final span = math.max(latSpan, lngSpan);
    if (span > 3) return 6.5;
    if (span > 1.5) return 7.5;
    if (span > 0.6) return 9.2;
    if (span > 0.2) return 10.5;
    return 12.5;
  }

  void _showPointBottomSheet(ReportMapPoint point) {
    if (point.isCluster) {
      _mapController.move(
        LatLng(point.lat, point.lng),
        (_mapController.camera.zoom + 2).clamp(4, 18),
      );
      final b = _mapController.camera.visibleBounds;
      _viewport = [b.south, b.west, b.north, b.east];
      _viewportZoom = _mapController.camera.zoom;
      _loadMap(silent: true);
      return;
    }
    final title = point.region.isNotEmpty ? point.region : point.address;
    final subtitle = point.address.trim().isNotEmpty && point.address != title
        ? point.address
        : '';
    _showDetailBottomSheet(
      title: title,
      subtitle: subtitle,
      total: point.total,
      regions: point.region.isNotEmpty ? [point.region] : const <String>[],
      agencies: point.agencyBreakdown,
      statuses: point.statusBreakdown,
      dispositions: point.dispositionBreakdown,
      categories: point.categoryBreakdown,
      onViewList: () {
        final address = _resolvePointAddress(point);
        final preferredCategory = _preferredCategoryForPoint(point);
        Navigator.of(context).pop();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _openAddressReportList(address, preferredCategory: preferredCategory);
        });
      },
    );
  }

  void _showClusterBottomSheet(List<ReportMapPoint> points) {
    if (points.isEmpty) return;
    final total = points.fold<int>(0, (sum, point) => sum + point.total);
    final agencies = _aggregateAgencies(points);
    final regionCounts = <String, int>{};
    for (final point in points) {
      final label = point.region.trim().isNotEmpty
          ? point.region.trim()
          : point.address.trim();
      if (label.isEmpty) continue;
      regionCounts[label] = (regionCounts[label] ?? 0) + point.total;
    }
    final sortedRegions = regionCounts.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    _showDetailBottomSheet(
      title: '묶음 신고 지점',
      subtitle: '${points.length}개 주소 · ${agencies.length}개 기관',
      total: total,
      regions: sortedRegions
          .take(5)
          .map((entry) => '${entry.key} (${entry.value}건)')
          .toList(),
      agencies: agencies,
      statuses: _aggregateBreakdown(
        points.expand((point) => point.statusBreakdown),
        total: total,
      ),
      dispositions: _aggregateBreakdown(
        points.expand((point) => point.dispositionBreakdown),
        total: total,
      ),
      categories: _aggregateBreakdown(
        points.expand((point) => point.categoryBreakdown),
        total: total,
      ),
    );
  }

  List<ReportMapAgencyItem> _aggregateAgencies(List<ReportMapPoint> points) {
    final counts = <String, int>{};
    final total = points.fold<int>(0, (sum, point) => sum + point.total);
    for (final point in points) {
      for (final agency in point.agencyBreakdown) {
        counts[agency.name] = (counts[agency.name] ?? 0) + agency.count;
      }
    }
    final items =
        counts.entries
            .map(
              (entry) => ReportMapAgencyItem(
                name: entry.key,
                count: entry.value,
                pct: total > 0 ? (entry.value / total) * 100 : 0,
              ),
            )
            .toList()
          ..sort((left, right) => right.count.compareTo(left.count));
    return items;
  }

  List<ReportMapBreakdownItem> _aggregateBreakdown(
    Iterable<ReportMapBreakdownItem> items, {
    required int total,
  }) {
    final counts = <String, int>{};
    for (final item in items) {
      counts[item.label] = (counts[item.label] ?? 0) + item.count;
    }
    final list =
        counts.entries
            .map(
              (entry) => ReportMapBreakdownItem(
                label: entry.key,
                count: entry.value,
                pct: total > 0 ? (entry.value / total) * 100 : 0,
              ),
            )
            .toList()
          ..sort((left, right) => right.count.compareTo(left.count));
    return list;
  }

  String _resolvePointAddress(ReportMapPoint point) {
    final address = point.address.trim();
    if (address.isNotEmpty) {
      return address;
    }
    return point.region.trim();
  }

  String? _preferredCategoryForPoint(ReportMapPoint point) {
    if (_selectedCategory == 'traffic' ||
        _selectedCategory == 'parking' ||
        _selectedCategory == 'other') {
      return _selectedCategory;
    }

    final counts = <String, int>{};
    for (final item in point.categoryBreakdown) {
      final label = item.label.trim();
      if (label == '교통위반') {
        counts['traffic'] = item.count;
      } else if (label == '주정차위반') {
        counts['parking'] = item.count;
      } else if (label == '기타위반') {
        counts['other'] = item.count;
      }
    }
    if (counts.isEmpty) {
      return null;
    }
    final sorted = counts.entries.toList()
      ..sort((left, right) {
        final countCompare = right.value.compareTo(left.value);
        if (countCompare != 0) {
          return countCompare;
        }
        return left.key.compareTo(right.key);
      });
    return sorted.first.value > 0 ? sorted.first.key : null;
  }

  void _openAddressReportList(String address, {String? preferredCategory}) {
    final normalizedAddress = address.trim();
    if (normalizedAddress.isEmpty) {
      showSrSnack(context, '주소 정보가 없어 리스트를 열 수 없습니다.', kind: SrSnackKind.error);
      return;
    }

    final provider = context.read<ReportProvider>();
    final tabIndex = provider.categoryToTabIndex(preferredCategory);
    // SQ-U02: 공용 필터(하단 신고내역 탭)를 바꾸지 않고 이 화면만의 조건으로 연다.
    pushReportDrillDown(
      Navigator.of(context),
      filter: ReportFilter(location: normalizedAddress),
      title: '$normalizedAddress · 신고',
      initialTabIndex: tabIndex,
    );
  }

  void _showDetailBottomSheet({
    required String title,
    required String subtitle,
    required int total,
    required List<String> regions,
    required List<ReportMapAgencyItem> agencies,
    required List<ReportMapBreakdownItem> statuses,
    required List<ReportMapBreakdownItem> dispositions,
    required List<ReportMapBreakdownItem> categories,
    VoidCallback? onViewList,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _countChip('$total건'),
                  ],
                ),
                if (subtitle.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: context.sr.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
                if (regions.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _sheetSection(
                    '행정구역',
                    regions.map((item) => _bulletText(item)).toList(),
                  ),
                ],
                if (agencies.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _sheetSection(
                    '담당 기관',
                    agencies
                        .take(8)
                        .map(
                          (item) => _bulletText(
                            '${item.name} (${item.count}건, ${item.pct.toStringAsFixed(1)}%)',
                          ),
                        )
                        .toList(),
                  ),
                ],
                if (statuses.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _sheetBreakdownSection('처리상태 비중', statuses),
                ],
                if (dispositions.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _sheetBreakdownSection('처분 현황 비중', dispositions),
                ],
                if (categories.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _sheetBreakdownSection('신고 종류 비중', categories),
                ],
                if (onViewList != null) ...[
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: onViewList,
                      icon: const Icon(Icons.list_alt_outlined, size: 18),
                      label: const Text('리스트 보기'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _countChip(String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _tone(serverSupplementColor).background,
        borderRadius: BorderRadius.circular(SrRadius.pill),
        border: Border.all(color: _tone(serverSupplementColor).border),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: _tone(serverSupplementColor).foreground,
        ),
      ),
    );
  }

  Widget _sheetSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget _sheetBreakdownSection(
    String title,
    List<ReportMapBreakdownItem> items,
  ) {
    return _sheetSection(
      title,
      items
          .map(
            (item) => _bulletText(
              '${item.label}: ${item.count}건 (${item.pct.toStringAsFixed(1)}%)',
            ),
          )
          .toList(),
    );
  }

  Widget _bulletText(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Icon(Icons.circle, size: 6, color: context.sr.textSecondary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPointMarker extends StatelessWidget {
  final ReportMapPoint point;

  const _MapPointMarker({required this.point});

  @override
  Widget build(BuildContext context) {
    final total = point.total;
    final circleSize = total >= 100
        ? 56.0
        : total >= 30
        ? 50.0
        : total >= 10
        ? 44.0
        : 38.0;
    final label = mapMarkerRegionLabel(point);
    final band = MapFineRateBand.of(point.fineRate);
    final markerColor = band.color;

    // 색만으로 구분하지 않도록 스크린리더에는 지역·건수·과태료율 구간을 읽어 준다(SQ-U24).
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '$label, $total건, ${band.label}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: circleSize,
            height: circleSize,
            decoration: BoxDecoration(
              color: markerColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: markerColor.withValues(alpha: 0.28),
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              '$total',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 6),
          MapMarkerRegionPill(label: label, maxWidth: _kMapMarkerLabelMaxWidth),
        ],
      ),
    );
  }
}

class _CurrentLocationMarker extends StatelessWidget {
  const _CurrentLocationMarker();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: cs.primary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: cs.primary.withValues(alpha: 0.35),
              blurRadius: 12,
              spreadRadius: 5,
            ),
          ],
        ),
        child: const Icon(
          Icons.person_pin_circle,
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }
}

class _ClusterMarkerWidget extends StatelessWidget {
  final int totalCount;
  final String regionLabel;

  const _ClusterMarkerWidget({
    required this.totalCount,
    required this.regionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final circleSize = totalCount >= 150
        ? 62.0
        : totalCount >= 60
        ? 56.0
        : totalCount >= 20
        ? 48.0
        : 42.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: circleSize,
          height: circleSize,
          decoration: BoxDecoration(
            color: kMapClusterColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000), // sr-allow: 지도 위 클러스터 그림자(테마 무관)
                blurRadius: 8,
                offset: Offset(0, 4),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            '$totalCount',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 6),
        MapMarkerRegionPill(
          label: regionLabel.trim().isNotEmpty
              ? regionLabel
              : '$totalCount건 묶음',
          maxWidth: _kMapMarkerLabelMaxWidth,
        ),
      ],
    );
  }
}

class _MapMarkerCache {
  const _MapMarkerCache({
    required this.payload,
    required this.validPoints,
    required this.markers,
    required this.lookup,
    required this.center,
    required this.zoom,
  });

  final ReportMapPayload? payload;
  final List<ReportMapPoint> validPoints;
  final List<Marker> markers;
  final Map<Marker, ReportMapPoint> lookup;
  final LatLng center;
  final double zoom;
}
