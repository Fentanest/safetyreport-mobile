// Opt-in, synthetic fixture only. Start PC scripts/dev/benchmark_client_search.py.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:safetyreport/providers/report_provider.dart';
import 'package:safetyreport/services/api_service.dart';
import 'package:safetyreport/services/client_report_scan.dart';
import 'package:safetyreport/services/performance_trace.dart';
import 'package:safetyreport/services/server_contract.dart';

class Metrics {
  int requests = 0, bytes = 0, jsonUs = 0, objectsUs = 0;
  double serviceMs = 0, responseMs = 0;
  void clear() {
    requests = 0;
    bytes = 0;
    jsonUs = 0;
    objectsUs = 0;
    serviceMs = 0;
    responseMs = 0;
  }

  Map<String, Object> result(Stopwatch timer) => {
    'requests': requests,
    'response_body_bytes': bytes,
    'elapsed_ms': timer.elapsedMicroseconds / 1000,
    'server_service_ms': serviceMs,
    'server_response_ms': responseMs,
    'dart_json_ms': jsonUs / 1000,
    'dart_report_objects_ms': objectsUs / 1000,
  };
}

class MeteredClient extends http.BaseClient {
  final http.Client inner = IOClient();
  final Metrics m;
  MeteredClient(this.m);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final r = await inner.send(request);
    m.requests++;
    m.serviceMs += double.tryParse(r.headers['x-bench-service-ms'] ?? '') ?? 0;
    m.responseMs +=
        double.tryParse(r.headers['x-bench-response-ms'] ?? '') ?? 0;
    return http.StreamedResponse(
      r.stream.map((data) {
        m.bytes += data.length;
        return data;
      }),
      r.statusCode,
      headers: r.headers,
      request: r.request,
      contentLength: r.contentLength,
      reasonPhrase: r.reasonPhrase,
    );
  }

  @override
  void close() => inner.close();
}

void main() {
  final dir = Platform.environment['SR_SEARCH_FIXTURE_DIR'];
  test(
    '60000 synthetic reports: actual legacy scan vs versioned HTTP search',
    () async {
      ServerContract.productVersion = '3.0.0+1';
      final api = ApiService(
        baseUrl: 'http://127.0.0.1:18764',
        apiKey: File('$dir/fixture-key.txt').readAsStringSync().trim(),
      );
      final provider = ReportProvider();
      addTearDown(provider.dispose);
      final metrics = Metrics();
      final results = <String, Object>{};
      PerformanceTrace.observer = (e) {
        if (e['stage'] == 'client.json_decode') {
          metrics.jsonUs += e['us'] as int;
        }
        if (e['stage'] == 'client.report_objects') {
          metrics.objectsUs += e['us'] as int;
        }
      };
      addTearDown(() => PerformanceTrace.observer = null);
      const filter = ReportFilter(name: 'école');
      Future<ReportPage> legacy(int offset) => scanClientReports(
        read: api.getReportsPage,
        categories: const ['traffic', 'parking', 'safety', 'living', 'other'],
        matches: (r) => provider.matchesFilter(r, filter: filter),
        isCancelled: () => false,
        offset: offset,
      );
      Future<ReportPage> search(int offset) =>
          api.getReportsPage('all', offset: offset, searchFilter: filter);
      Future<ReportPage> measure(
        String name,
        Future<ReportPage> Function() work,
      ) async {
        metrics.clear();
        final watch = Stopwatch()..start();
        final result = await work();
        results[name] = {
          ...metrics.result(watch),
          'total': result.total,
          'rows': result.reports.length,
        };
        return result;
      }

      await http.runWithClient(() async {
        // Warm compatibility handshake, measured separately from report queries.
        metrics.clear();
        final watch = Stopwatch()..start();
        final cfg = await api.getAppConfig();
        expect(cfg['report_search_version'], 1);
        results['cold_capability_and_compatibility'] = metrics.result(watch);
        final old = await measure(
          'before_apply_first_and_exact_total',
          () => legacy(0),
        );
        final fresh = await measure(
          'after_apply_first_and_exact_total',
          () => search(0),
        );
        expect(fresh.total, old.total);
        expect(
          fresh.reports.map((r) => r.id),
          old.reports.take(200).map((r) => r.id),
        );
        final next = await measure('after_prefetch_next', () => search(200));
        await measure(
          'before_next_cached',
          () async =>
              (reports: old.reports.skip(200).toList(), total: old.total),
        );
        await measure('after_next_cached', () async => next);
        await measure(
          'before_previous_cached',
          () async =>
              (reports: old.reports.take(200).toList(), total: old.total),
        );
        await measure('after_previous_cached', () async => fresh);
        // Crossing the old 400-match window repeats the source download.
        final old400 = await measure(
          'before_next_window_400',
          () => legacy(400),
        );
        final new400 = await measure(
          'after_next_prefetch_400',
          () => search(400),
        );
        expect(
          new400.reports.map((r) => r.id),
          old400.reports.take(200).map((r) => r.id),
        );
        final farOld = await measure('before_far_10000', () => legacy(10000));
        final far = await measure('after_far_10000', () => search(10000));
        expect(far.total, farOld.total);
        expect(
          far.reports.map((r) => r.id),
          farOld.reports.take(200).map((r) => r.id),
        );
        await measure('after_far_prefetch_10200', () => search(10200));
      }, () => MeteredClient(metrics));
      final output = const JsonEncoder.withIndent('  ').convert(results);
      File('.agent-runs/search/benchmark.json').writeAsStringSync(output);
      // ignore: avoid_print
      print(output);
    },
    skip: dir == null ? 'opt-in synthetic HTTP benchmark' : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
