// Client 모드 서버 DB 다운로드 (`ApiService.downloadDbToFile`).
// 1.3.5 증상: 전체 2분 제한 + 이전 요청을 끊지 않는 최대 5회 재시도로, 느린 회선에서 최대 약 10분 스피너만 돌았다.
// 지금 규칙: 파일로 흘려 받기, 무응답 시간 제한(요청을 실제로 닫음), 자동 재시도 없음, 조각 파일은 성공 때만 이름 바꿈, 취소 가능.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safetyreport/services/api_service.dart';

/// 본문을 직접 흘려 보내는 가짜 서버. close() 는 실제 클라이언트처럼 진행 중인 응답을 끊는다.
class _StreamingClient extends http.BaseClient {
  _StreamingClient({this.status = 200, this.contentLength});

  final int status;
  final int? contentLength;
  final body = StreamController<List<int>>();
  final requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(body.stream, status, contentLength: contentLength);
  }

  @override
  void close() {
    closed = true;
    if (!body.isClosed) {
      body.addError(http.ClientException('Connection closed'));
      body.close();
    }
  }
}

void main() {
  late Directory dir;
  late String target;
  final api = ApiService(baseUrl: 'https://nas.example.test', apiKey: 'k');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('db_download_');
    target = '${dir.path}/backup.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> files() => dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  test('streams the body to the file with progress, sends the API key once, leaves no partial file', () async {
    final client = _StreamingClient(contentLength: 6);
    final progress = <(int, int?)>[];
    final done = api.downloadDbToFile(target, client: client, onProgress: (r, t) => progress.add((r, t)));
    client.body.add([1, 2, 3]);
    client.body.add([4, 5, 6]);
    await client.body.close();
    expect(await done, 6);
    expect(File(target).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
    expect(files(), ['backup.db']);
    expect(progress, [(0, 6), (3, 6), (6, 6)]);
    expect(client.requests.single.url.path, '/api/v1/settings/db');
    expect(client.requests.single.headers['X-API-Key'], 'k');
  });

  test('stops when no byte arrives for the idle timeout, closes the request, and does not retry', () async {
    final client = _StreamingClient(contentLength: 10);
    final done = api.downloadDbToFile(target, client: client, idleTimeout: const Duration(milliseconds: 150));
    client.body.add([1, 2, 3]);
    await expectLater(
      done,
      throwsA(isA<Exception>().having((e) => '$e', 'message', contains('데이터가 오지 않아'))),
    );
    expect(client.requests, hasLength(1), reason: '큰 파일은 자동으로 처음부터 다시 받지 않는다');
    expect(files(), isEmpty, reason: '받다 만 조각은 지운다');
  });

  test('a body shorter than Content-Length is an error, not a truncated backup', () async {
    final client = _StreamingClient(contentLength: 10);
    final done = api.downloadDbToFile(target, client: client);
    client.body.add([1, 2, 3]);
    await client.body.close();
    await expectLater(done, throwsA(isA<Exception>().having((e) => '$e', 'message', contains('중간에 끊겼습니다'))));
    expect(files(), isEmpty);
  });

  test('a server error shows the status and detail and writes nothing', () async {
    final client = _StreamingClient(status: 403);
    final done = api.downloadDbToFile(target, client: client);
    client.body.add(utf8.encode(jsonEncode({'detail': '커뮤니티 필수 설정이 필요합니다'})));
    await client.body.close();
    await expectLater(done, throwsA(isA<Exception>().having((e) => '$e', 'message', allOf(contains('403'), contains('필수 설정')))));
    expect(files(), isEmpty);
  });

  test('cancel closes the request right away and removes the partial file', () async {
    final client = _StreamingClient(contentLength: 10);
    final cancel = DownloadCancel();
    final done = api.downloadDbToFile(target, client: client, cancel: cancel, idleTimeout: const Duration(minutes: 5));
    client.body.add([1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cancel.cancel();
    await expectLater(done, throwsA(isA<DownloadCancelled>()));
    expect(client.closed, isTrue);
    expect(files(), isEmpty);
  });

  test('with a real socket: a stalled server is cut off after the idle timeout (the connection is closed)', () async {
    // 헤더와 64KB 만 보내고 멈추는 서버. 클라이언트가 연결을 닫으면 읽기 쪽이 끝난다(EOF).
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final clientClosed = Completer<void>();
    server.listen((socket) {
      var sent = false;
      socket.listen(
        (_) {
          if (sent) return;
          sent = true;
          socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n'
              'Content-Length: ${31 * 1024 * 1024}\r\n\r\n'));
          socket.add(List<int>.filled(64 * 1024, 7));
        },
        onDone: () {
          if (!clientClosed.isCompleted) clientClosed.complete();
          socket.destroy();
        },
        onError: (_) {
          if (!clientClosed.isCompleted) clientClosed.complete();
        },
      );
    });
    addTearDown(server.close);
    final realApi = ApiService(baseUrl: 'http://127.0.0.1:${server.port}', apiKey: 'k');
    final sw = Stopwatch()..start();
    await expectLater(
      realApi.downloadDbToFile(target, idleTimeout: const Duration(milliseconds: 300)),
      throwsA(isA<Exception>().having((e) => '$e', 'message', contains('데이터가 오지 않아'))),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    await clientClosed.future.timeout(const Duration(seconds: 5));
    expect(files(), isEmpty);
  });
}
