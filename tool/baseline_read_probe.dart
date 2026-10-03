import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/services/agency_registry.dart';
import 'large_data_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await (await SharedPreferences.getInstance()).setBool(
    'standaloneDemoMode',
    true,
  );
  await AgencyRegistry.ensureLoaded();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('baseline 합성 자료'))),
    ),
  );
  await seedLargeDataFixture(await LocalDbService.db, 58388);
  for (final phase in ['cold', 'warm']) {
    final t = Stopwatch()..start();
    final summary = await LocalDbService.computeSummary(
      useRepresentativeRecords: true,
    );
    debugPrint(
      'SR_BASELINE ${jsonEncode({'stage': 'summary', 'phase': phase, 'rows': 58388, 'total': summary.total, 'ms': t.elapsedMilliseconds, 'rss': ProcessInfo.currentRss})}',
    );
    t.reset();
    await LocalDbService.computeStats(useRepresentativeRecords: true);
    await LocalDbService.computeStatsOverview(useRepresentativeRecords: true);
    debugPrint(
      'SR_BASELINE ${jsonEncode({'stage': 'stats_bundle', 'phase': phase, 'rows': 58388, 'ms': t.elapsedMilliseconds, 'rss': ProcessInfo.currentRss, 'peak_rss': ProcessInfo.maxRss})}',
    );
  }
}
