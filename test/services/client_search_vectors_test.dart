import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/agency_registry.dart';
import 'package:safetyreport/providers/report_provider.dart';

ReportFilter searchFilterFromJson(Map f) => ReportFilter(
  name: f['name'] ?? '',
  reportNumber: f['reportNumber'] ?? '',
  id: f['id'] ?? '',
  ratings: List<String>.from(f['ratings'] ?? []),
  ratingCause: f['ratingCause'] ?? '',
  agency: f['agency'] ?? '',
  manager: f['manager'] ?? '',
  carNumber: f['carNumber'] ?? '',
  law: f['law'] ?? '',
  location: f['location'] ?? '',
  fine: f['fine'] ?? '',
  supplementCount: f['supplementCount'] ?? '',
  reportContent: f['reportContent'] ?? '',
  processContent: f['processContent'] ?? '',
  statuses: List<String>.from(f['statuses'] ?? []),
  reportDateStart: f['reportDateStart'] ?? '',
  reportDateEnd: f['reportDateEnd'] ?? '',
  occurDateStart: f['occurDateStart'] ?? '',
  occurDateEnd: f['occurDateEnd'] ?? '',
  responseDateStart: f['responseDateStart'] ?? '',
  responseDateEnd: f['responseDateEnd'] ?? '',
  occurTimeStart: f['occurTimeStart'] ?? '',
  occurTimeEnd: f['occurTimeEnd'] ?? '',
  excludePolice: f['excludePolice'] ?? false,
  onlyPolice: f['onlyPolice'] ?? false,
  pollStatus: f['pollStatus'] ?? '',
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'PC exact SQL vectors equal existing Dart filters, including Unicode',
    () async {
      await AgencyRegistry.ensureLoaded();
      expect(AgencyRegistry.cacheVersion, isNotNull);
      final vectors =
          jsonDecode(
                File('contracts/client-search-vectors.json').readAsStringSync(),
              )
              as Map;
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      final rows =
          (vectors['rows'] as List)
              .map((r) => Report.fromJson(Map<String, dynamic>.from(r)))
              .toList()
            ..sort((a, b) {
              final n = b.reportNumber.compareTo(a.reportNumber);
              return n != 0 ? n : b.id.compareTo(a.id);
            });
      for (final c in vectors['cases']) {
        final filter = searchFilterFromJson(c['filter']);
        expect(
          rows
              .where((r) => provider.matchesFilter(r, filter: filter))
              .map((r) => r.id),
          c['ids'],
          reason: '${c['filter']}',
        );
      }
    },
  );
}
