import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/widgets/report_detail_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = '$value';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(this.statusCode)
    : super(Stream.value(statusCode == 200 ? _png : <int>[]));
  static final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
  );
  @override
  final int statusCode;
  @override
  int get contentLength => statusCode == 200 ? _png.length : 0;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.respond);
  final int Function(Map<String, String>) respond;
  @override
  final _Headers headers = _Headers();
  @override
  Future<HttpClientResponse> close() async =>
      _Response(respond(headers.values));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.respond);
  final int Function(Map<String, String>) respond;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _Request(respond);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final scenario in [
    'public',
    '401',
    '403',
    'expired',
    'missing',
    'foreign',
  ]) {
    testWidgets('photo auth: $scenario', (tester) async {
      SharedPreferences.setMockInitialValues({
        'standaloneUsername': 'fixture',
        'standaloneTokenUsername': 'fixture',
        if (scenario != 'missing') 'standaloneToken': 'synthetic-expired-token',
      });
      final requests = <Map<String, String>>[];
      debugNetworkImageHttpClientProvider = () => _Client((headers) {
        requests.add(Map.of(headers));
        if (scenario == 'public') return headers.isEmpty ? 200 : 401;
        if (scenario == 'expired' ||
            scenario == 'missing' ||
            scenario == 'foreign') {
          return 401;
        }
        return headers.isEmpty ? int.parse(scenario) : 200;
      });
      addTearDown(() {
        debugNetworkImageHttpClientProvider = null;
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      });
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final host = scenario == 'foreign'
          ? 'safetyreport.go.kr.evil.test'
          : 'www.safetyreport.go.kr';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportDetailSheet(
              report: Report.fromJson({
                '신고일': '2099-01-01',
                '첨부사진': 'https://$host/fileDown?case=$scenario',
              }),
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(requests, isNotEmpty);
      expect(requests.first, isEmpty);
      final retries = ['401', '403', 'expired'].contains(scenario);
      expect(requests.length, retries ? 2 : 1);
      if (retries) {
        expect(
          requests.last['Authorization'],
          'BEARER synthetic-expired-token',
        );
      }
      if (['expired', 'missing', 'foreign'].contains(scenario)) {
        expect(find.text('다시 시도'), findsOneWidget);
      } else {
        expect(find.text('다시 시도'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      debugNetworkImageHttpClientProvider = null;
    });
  }
}
