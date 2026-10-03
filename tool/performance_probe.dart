// Isolated fixture entrypoint. Build with SR_TEST_APPLICATION_ID=...fixture;
// never install on a personal device. No production entrypoint instrumentation.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/models/app_mode.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/providers/notification_history_provider.dart';
import 'package:safetyreport/screens/dashboard_screen.dart';
import 'package:safetyreport/screens/statistics_screen.dart';
import 'package:safetyreport/screens/report_map_screen.dart';
import 'package:safetyreport/services/agency_registry.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/services/db_export_location.dart';
import 'package:safetyreport/services/duplicate_projection_service.dart';
import 'package:safetyreport/screens/duplicate_management_screen.dart';
import 'package:safetyreport/services/server_contract.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/widgets/rating_dialog.dart';
import 'large_data_fixture.dart';

void emit(Map<String, Object?> data) =>
    debugPrint('SR_PROBE ${jsonEncode(data)}');

class _Offline extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = (_, _, _) => Future.error(
          const SocketException('Fixture: external network disabled'),
        );
}

class _ProbeProvider extends ReportProvider {
  @override
  AppMode get appMode => AppMode.standalone;
  @override
  bool get isConfigured => true;
  @override
  bool get isStandaloneDemo => true;
  @override
  bool get excludeWithdraw => true;
  @override
  bool get useRepresentativeRecords => true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ServerContract.loadProductVersion();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('standaloneDemoMode', true);
  HttpOverrides.global = _Offline();
  final timer = Stopwatch()..start();
  await AgencyRegistry.ensureLoaded();
  emit({'stage': 'registry.cold_load', 'ms': timer.elapsedMilliseconds});
  var frameCount = 0, maxBuild = 0, maxRaster = 0;
  SchedulerBinding.instance.addTimingsCallback((frames) {
    for (final frame in frames) {
      frameCount++;
      if (frame.buildDuration.inMicroseconds > maxBuild) {
        maxBuild = frame.buildDuration.inMicroseconds;
      }
      if (frame.rasterDuration.inMicroseconds > maxRaster) {
        maxRaster = frame.rasterDuration.inMicroseconds;
      }
    }
    emit({
      'stage': 'frames',
      'count': frameCount,
      'max_build_us': maxBuild,
      'max_raster_us': maxRaster,
    });
  });
  final probeProvider = _ProbeProvider();
  await probeProvider.setStandaloneConfig(
    'fixture',
    phoneNumber: 'fixture',
    isDemoMode: true,
  );
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ReportProvider>(create: (_) => probeProvider),
        ChangeNotifierProvider(create: (_) => NotificationHistoryProvider()),
      ],
      child: const _ProbeApp(),
    ),
  );
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();
  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  String _status = '준비';
  Widget? _screen;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _benchmark());
  }

  Future<void> _benchmark() async {
    const requested = String.fromEnvironment('SR_ROWS');
    final sizes = requested.isEmpty
        ? [0, 1, 3000, 58388, 100000, 500000]
        : [int.parse(requested)];
    for (final n in sizes) {
      setState(() => _status = '$n건 합성 fixture 생성 중');
      final seed = Stopwatch()..start();
      const reuse = bool.fromEnvironment('SR_REUSE_FIXTURE');
      if (!reuse) {
        await seedLargeDataFixture(await LocalDbService.db, n);
      } else {
        final count = await LocalDbService.getTotalCount();
        if (count != n) {
          throw StateError('Fixture contains $count reports, expected $n');
        }
      }
      emit({
        'rows': n,
        'stage': 'fixture.seed',
        'ms': seed.elapsedMilliseconds,
      });
      final stageTotals = <String, Map<String, int>>{};
      PerformanceTrace.observer = (e) {
        final value = stageTotals.putIfAbsent(
          e['stage'] as String,
          () => {'us': 0, 'returned_rows': 0},
        );
        final stage = e['stage'] as String;
        if (stage.startsWith('summary.') ||
            stage.endsWith('.total') ||
            stage == 'stats.sql_group') {
          emit({'stage': 'measured_stage', ...e});
        }
        value['us'] = value['us']! + (e['us'] as int);
        value['returned_rows'] =
            value['returned_rows']! + ((e['rows'] as int?) ?? 0);
      };
      if (const bool.fromEnvironment('SR_DUPLICATE_ONLY')) {
        for (final phase in ['cold', 'warm']) {
          final t = Stopwatch()..start();
          var rawPageMax = 0, fieldPageMax = 0, digestRows = 0;
          var sampled = false, readReady = false;
          Future<void>? concurrentRead;
          final prior = PerformanceTrace.observer;
          PerformanceTrace.observer = (e) {
            prior?.call(e);
            if (e['stage'] == 'duplicate.sql_page') {
              final rows = e['rows'] as int;
              if (rows > rawPageMax) rawPageMax = rows;
            }
            if (e['stage'] == 'duplicate.digest') {
              digestRows += e['rows'] as int;
            }
            if (e['stage'] == 'duplicate.field_page') {
              final rows = e['rows'] as int;
              if (rows > fieldPageMax) fieldPageMax = rows;
              if (!sampled) {
                sampled = true;
                concurrentRead = Future<void>(() async {
                  final read = Stopwatch()..start();
                  LocalDbService.invalidateCaches();
                  final s = await LocalDbService.computeSummary();
                  readReady = true;
                  emit({
                    'stage': 'duplicate.concurrent_summary',
                    'phase': phase,
                    'rows': s.total,
                    'ms': read.elapsedMilliseconds,
                  });
                });
              }
            }
          };
          final result =
              await DuplicateProjectionService.refreshDuplicateGroups(
                await LocalDbService.db,
              );
          final readyAtPublish = readReady;
          await concurrentRead;
          emit({
            'stage': 'duplicate',
            'phase': phase,
            'rows': n,
            'ms': t.elapsedMilliseconds,
            'groups': result['group_count'],
            'members': result['member_count'],
            'raw_page_max': rawPageMax,
            'field_page_max': fieldPageMax,
            'digest_rows': digestRows,
            'summary_ready_before_publish': readyAtPublish,
            'rss': ProcessInfo.currentRss,
            'peak_rss': ProcessInfo.maxRss,
          });
          PerformanceTrace.observer = prior;
        }
        PerformanceTrace.observer = null;
        setState(() => _status = '$n건 중복 재계산 측정 완료');
        emit({'stage': 'complete'});
        return;
      }
      for (final phase in ['cold', 'warm']) {
        final t = Stopwatch()..start();
        final summary = await LocalDbService.computeSummary(
          excludeWithdraw: true,
          useRepresentativeRecords: true,
        );
        emit({
          'rows': n,
          'phase': phase,
          'stage': 'summary',
          'ms': t.elapsedMilliseconds,
          'total': summary.total,
          'rss': ProcessInfo.currentRss,
        });
        t.reset();
        final stats = await LocalDbService.computeStatsBundle(
          excludeWithdraw: true,
          useRepresentativeRecords: true,
        );
        emit({
          'rows': n,
          'phase': phase,
          'stage': 'stats',
          'ms': t.elapsedMilliseconds,
          'total': stats['overview']['all']['total'],
          'rss': ProcessInfo.currentRss,
        });
        t.reset();
        final map = await LocalDbService.computeReportMapStats(
          excludeWithdraw: true,
          useRepresentativeRecords: true,
        );
        emit({
          'rows': n,
          'phase': phase,
          'stage': 'map',
          'ms': t.elapsedMilliseconds,
          'points': (map['points'] as List).length,
          'rss': ProcessInfo.currentRss,
        });
      }
      emit({
        'rows': n,
        'stage': 'stages',
        'values': stageTotals,
        'peak_rss': ProcessInfo.maxRss,
      });
      PerformanceTrace.observer = null;
      if (n == 500000) {
        // Aggregation/navigation cycle without network. The buttons below allow
        // actual keyboard, file-app, rotation, lifecycle and screen verification.
        for (var i = 0; i < 20; i++) {
          await LocalDbService.computeSummary(
            excludeWithdraw: true,
            useRepresentativeRecords: true,
          );
          await LocalDbService.computeStatsBundle(
            excludeWithdraw: true,
            useRepresentativeRecords: true,
          );
          await LocalDbService.computeReportMapStats(
            excludeWithdraw: true,
            useRepresentativeRecords: true,
          );
        }
        emit({
          'rows': n,
          'stage': 'repeat20',
          'rss': ProcessInfo.currentRss,
          'peak_rss': ProcessInfo.maxRss,
        });
      }
      setState(() => _status = '$n건 측정 완료');
    }
    emit({'stage': 'complete'});
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('합성 자료 검증')),
        body: Column(
          children: [
            Text(_status),
            Wrap(
              children: [
                TextButton(
                  onPressed: () {
                    context.read<ReportProvider>().fetchSummary();
                    setState(() => _screen = const DashboardScreen());
                  },
                  child: const Text('대시보드'),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _screen = const StatisticsScreen()),
                  child: const Text('통계'),
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ReportMapScreen()),
                  ),
                  child: const Text('지도'),
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _screen = const DuplicateManagementPanel(),
                  ),
                  child: const Text('중복'),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const RatingDialog(
                      count: 2,
                      eligibleCount: 2,
                      causeSupported: true,
                    ),
                  ),
                  child: const Text('사유'),
                ),
                TextButton(
                  onPressed: () async {
                    final staged = await DbExportLocation.stage(
                      'fixture_${DateTime.now().millisecondsSinceEpoch}.db',
                    );
                    try {
                      await LocalDbService.exportBackup(staged.path);
                      final saved = await DbExportLocation.publish(staged);
                      if (saved != null && context.mounted) {
                        await DbExportLocation.completed(context, saved);
                      }
                    } finally {
                      if (await staged.exists()) await staged.delete();
                    }
                  },
                  child: const Text('DB 저장'),
                ),
              ],
            ),
            Expanded(
              child:
                  _screen ??
                  const Center(child: Text('외부 네트워크 차단 · 합성 자료만 사용')),
            ),
          ],
        ),
      ),
    ),
  );
}
