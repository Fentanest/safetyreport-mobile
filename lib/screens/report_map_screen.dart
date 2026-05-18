import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../models/report.dart';
import '../models/report_map.dart';
import '../providers/report_provider.dart';
import '../server_palette.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/local_geocode_service.dart';
import '../widgets/report_detail_sheet.dart';
import '../widgets/report_list_card.dart';
import 'report_list_screen.dart';
import 'settings_screen.dart';

const double _kMapMarkerWidth = 100;
const double _kMapMarkerHeight = 98;
const double _kMapMarkerLabelMaxWidth = 92;
const EdgeInsets _kMapMarkerLabelPadding = EdgeInsets.symmetric(
  horizontal: 8,
  vertical: 3,
);

Color _mapPointColorForFineRate(double fineRate) {
  if (fineRate >= 60) {
    return const Color(0xFF2E7D32);
  }
  if (fineRate >= 50) {
    return const Color(0xFFF57C00);
  }
  return const Color(0xFFC62828);
}

class ReportMapScreen extends StatefulWidget {
  final String initialYear;
  final String initialCategory;

  const ReportMapScreen({
    super.key,
    this.initialYear = 'all',
    this.initialCategory = 'all',
  });

  @override
  State<ReportMapScreen> createState() => _ReportMapScreenState();
}

class _ReportMapScreenState extends State<ReportMapScreen> {
  ReportMapPayload? _payload;
  GeocodeBackfillProgress? _progress;
  bool _loading = true;
  String? _error;
  Timer? _progressTimer;
  String _selectedYear = 'all';
  String _selectedCategory = 'all';

  @override
  void initState() {
    super.initState();
    _selectedYear = widget.initialYear;
    _selectedCategory = widget.initialCategory;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMap());
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadMap({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final provider = context.read<ReportProvider>();
    try {
      ReportMapPayload payload;
      GeocodeBackfillProgress progress;
      if (provider.appMode == AppMode.standalone) {
        progress = await LocalGeocodeService.ensureMapBackfillStarted(
          apiKey: provider.standaloneKakaoRestApiKey,
          batchSize: 80,
        );
        payload = ReportMapPayload.fromJson(
          await LocalDbService.computeReportMapStats(
            year: _selectedYear == 'all' ? null : _selectedYear,
            category: _selectedCategory,
            excludeWithdraw: provider.excludeWithdraw,
            normalizePolice: provider.normalizePolice,
            useRepresentativeRecords: provider.useRepresentativeRecords,
          ),
        );
      } else {
        final api = ApiService(
          baseUrl: provider.baseUrl,
          apiKey: provider.apiKey,
        );
        payload = await api.getReportMapStats(
          year: _selectedYear == 'all' ? null : _selectedYear,
          category: _selectedCategory,
        );
        progress = await api.getReportMapProgress();
      }

      if (!mounted) return;
      setState(() {
        _payload = payload;
        _progress = progress;
        _loading = false;
        _error = null;
      });
      _syncProgressPolling(progress);
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$exc';
      });
    }
  }

  void _syncProgressPolling(GeocodeBackfillProgress progress) {
    _progressTimer?.cancel();
    if (!progress.running) return;
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final provider = context.read<ReportProvider>();
      try {
        GeocodeBackfillProgress next;
        if (provider.appMode == AppMode.standalone) {
          next = LocalGeocodeService.currentProgress();
        } else {
          next = await ApiService(
            baseUrl: provider.baseUrl,
            apiKey: provider.apiKey,
          ).getReportMapProgress();
        }

        if (!mounted) return;
        setState(() => _progress = next);
        if (!next.running) {
          _progressTimer?.cancel();
          await _loadMap(silent: true);
        }
      } catch (_) {
        _progressTimer?.cancel();
      }
    });
  }

  List<String> get _availableYears {
    final years = _payload?.meta.availableYears ?? const <String>[];
    return ['all', ...years.where((year) => year != 'all')];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final progress = _progress;
    final payload = _payload;
    final points = (payload?.points ?? const <ReportMapPoint>[])
        .where((point) => point.hasValidCoordinates)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('신고 지도'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt_outlined),
            tooltip: '미변환 주소 보기',
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
                if (progress != null &&
                    (progress.running ||
                        progress.errorMessage.isNotEmpty ||
                        progress.requiresConfiguration))
                  _buildProgressCard(progress),
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
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: points.isEmpty
                        ? _buildEmptyState(progress)
                        : _buildMap(points),
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
          bottom: BorderSide(color: cs.outlineVariant.withOpacity(0.35)),
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
        ],
      ),
    );
  }

  Future<ReportMapMissingPayload> _loadMissingAddressGroups() async {
    final provider = context.read<ReportProvider>();
    if (provider.appMode == AppMode.standalone) {
      return ReportMapMissingPayload.fromJson(
        await LocalDbService.computeReportMapMissingGroups(
          year: _selectedYear == 'all' ? null : _selectedYear,
          category: _selectedCategory,
          excludeWithdraw: provider.excludeWithdraw,
          normalizePolice: provider.normalizePolice,
          useRepresentativeRecords: provider.useRepresentativeRecords,
        ),
      );
    }

    final api = ApiService(baseUrl: provider.baseUrl, apiKey: provider.apiKey);
    return api.getReportMapMissingGroups(
      year: _selectedYear == 'all' ? null : _selectedYear,
      category: _selectedCategory,
    );
  }

  void _showMissingAddressSheet() {
    final future = _loadMissingAddressGroups();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.84,
          minChildSize: 0.45,
          maxChildSize: 0.96,
          builder: (context, scrollController) =>
              FutureBuilder<ReportMapMissingPayload>(
                future: future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      children: [
                        const Text(
                          '미변환 주소 목록',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildErrorCard('${snapshot.error}'),
                      ],
                    );
                  }

                  final payload =
                      snapshot.data ??
                      const ReportMapMissingPayload(
                        groups: <ReportMapMissingGroup>[],
                        groupCount: 0,
                        reportCount: 0,
                      );

                  return ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      const Text(
                        '미변환 주소 목록',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '좌표가 아직 없는 주소 ${payload.groupCount}곳 · 신고 ${payload.reportCount}건',
                        style: const TextStyle(color: Colors.grey, height: 1.4),
                      ),
                      const SizedBox(height: 14),
                      if (payload.groups.isEmpty)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.task_alt,
                                  size: 42,
                                  color: Colors.green.shade600,
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  '현재 조건에서 미변환 주소가 없습니다.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        ...payload.groups.map(_buildMissingAddressGroupCard),
                    ],
                  );
                },
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
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: serverSupplementColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '${group.reportCount}건',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: serverSupplementColor,
            ),
          ),
        ),
        children: group.reports
            .map((report) => _buildMissingReportCard(report))
            .toList(),
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

  Widget _buildProgressCard(GeocodeBackfillProgress progress) {
    final provider = context.watch<ReportProvider>();
    final isStandalone = provider.appMode == AppMode.standalone;
    final isWarning = progress.isWarning;
    final isConfigRequired =
        progress.requiresConfiguration && !progress.isWarning;
    final accentColor = progress.isError
        ? Colors.red
        : isWarning || isConfigRequired
        ? Colors.orange
        : Colors.blueGrey;
    final cardColor = progress.isError
        ? Colors.red.withOpacity(0.05)
        : isWarning || isConfigRequired
        ? Colors.orange.withOpacity(0.08)
        : Colors.blue.withOpacity(0.05);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Card(
        color: cardColor,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    progress.isError
                        ? Icons.error_outline
                        : isWarning || isConfigRequired
                        ? Icons.warning_amber_rounded
                        : Icons.public,
                    color: accentColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      progress.isError
                          ? '좌표 변환을 마치지 못했습니다'
                          : isWarning
                          ? '저장된 좌표로 지도는 계속 표시됩니다'
                          : isConfigRequired
                          ? 'REST API 키를 입력하면 좌표 변환을 시작합니다'
                          : progress.running
                          ? '주소 좌표 변환 진행 중'
                          : '주소 좌표 변환 완료',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: progress.running ? progress.progressPct / 100 : 1,
                minHeight: 8,
                borderRadius: BorderRadius.circular(999),
                color: accentColor,
              ),
              const SizedBox(height: 10),
              Text(
                '진행률 ${progress.progressPct.toStringAsFixed(1)}%  ·  ${progress.processed}/${progress.total}건 처리',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                '성공 ${progress.updated}건 · 주소 미발견 ${progress.notFound}건 · 남은 대상 ${progress.remainingMissing}건',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (progress.errorMessage.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  progress.errorMessage,
                  style: TextStyle(
                    fontSize: 12,
                    color: progress.isError
                        ? Colors.red
                        : Colors.orange.shade800,
                    height: 1.4,
                  ),
                ),
                if (progress.requiresConfiguration && isStandalone)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      label: const Text('모바일 설정 열기'),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ).then((_) => _loadMap()),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard(String message) {
    return Card(
      color: Colors.red.withOpacity(0.05),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.red),
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _smallStat('전체', meta.totalReports, Colors.blue),
        _smallStat('좌표화', meta.geocodedReports, serverAcceptColor),
        _smallStat('미변환', meta.missingReports, serverSupplementColor),
        _smallStat('처리기관', meta.agencyCount, Colors.teal),
      ],
    );
  }

  Widget _smallStat(String label, int value, Color color) {
    return Container(
      constraints: const BoxConstraints(minWidth: 76),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$value건',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(GeocodeBackfillProgress? progress) {
    final message = progress != null && progress.running
        ? '주소 좌표를 채우는 중입니다.\n완료되면 지도가 자동으로 표시됩니다.'
        : progress?.isWarning == true
        ? '저장된 좌표가 있는 신고는 계속 지도에 표시됩니다.\n다만 DB에 없는 새 주소는 카카오 REST API 키를 다시 입력해야 변환할 수 있습니다.'
        : progress?.requiresConfiguration == true
        ? '카카오 REST API 키를 입력하면 지도 좌표 변환을 시작합니다.'
        : '표시할 지도 데이터가 없습니다.';
    return Card(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 48, color: Colors.grey.shade500),
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

  Widget _buildMap(List<ReportMapPoint> points) {
    final center = _computeCenter(points);
    final zoom = _suggestZoom(points);
    final markerLookup = <Marker, ReportMapPoint>{};
    final markers = points.map((point) {
      final marker = Marker(
        point: LatLng(point.lat, point.lng),
        width: _kMapMarkerWidth,
        height: _kMapMarkerHeight,
        child: _MapPointMarker(point: point),
      );
      markerLookup[marker] = point;
      return marker;
    }).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: FlutterMap(
        key: ValueKey(
          '${_selectedYear}_${_selectedCategory}_${points.length}_${_progress?.state}',
        ),
        options: MapOptions(
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
          ),
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
                  (sum, marker) => sum + (markerLookup[marker]?.total ?? 0),
                ),
                regionLabel: _clusterRegionLabel(
                  clusterMarkers
                      .map((marker) => markerLookup[marker])
                      .whereType<ReportMapPoint>()
                      .toList(),
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
        ],
      ),
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

  String _clusterRegionLabel(List<ReportMapPoint> points) {
    if (points.isEmpty) return '';
    final counts = <String, int>{};
    for (final point in points) {
      final label = point.region.trim().isNotEmpty
          ? point.region.trim()
          : point.address.trim();
      if (label.isEmpty) continue;
      counts[label] = (counts[label] ?? 0) + point.total;
    }
    if (counts.isEmpty) return '';
    final sorted = counts.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    return sorted.first.key;
  }

  void _showPointBottomSheet(ReportMapPoint point) {
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('주소 정보가 없어 리스트를 열 수 없습니다.')));
      return;
    }

    final provider = context.read<ReportProvider>();
    provider.setFilter(ReportFilter(location: normalizedAddress));
    final tabIndex = provider.categoryToTabIndex(preferredCategory);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportListScreen(initialTabIndex: tabIndex),
      ),
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
                    style: const TextStyle(color: Colors.grey, height: 1.4),
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
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFFFCC80)),
      ),
      child: Text(
        value,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: Color(0xFFE65100),
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
          const Padding(
            padding: EdgeInsets.only(top: 7),
            child: Icon(Icons.circle, size: 6, color: Colors.blueGrey),
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
    final label = point.region.trim().isNotEmpty ? point.region : point.address;
    final markerColor = _mapPointColorForFineRate(point.fineRate);

    return Column(
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
        _MarkerRegionPill(label: label),
      ],
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
            color: const Color(0xFF0D47A1),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
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
        if (regionLabel.trim().isNotEmpty)
          _MarkerRegionPill(label: regionLabel),
      ],
    );
  }
}

class _MarkerRegionPill extends StatelessWidget {
  final String label;

  const _MarkerRegionPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: _kMapMarkerLabelMaxWidth),
      padding: _kMapMarkerLabelPadding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black12),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    );
  }
}
