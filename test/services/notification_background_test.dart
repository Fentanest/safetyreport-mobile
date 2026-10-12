import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/services/notification_background.dart';
import 'package:safetyreport/services/prefs_inbox.dart';

const key =
    'inbox.enqueue.native.notification.00000000-0000-0000-0000-000000000000';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fentanest.mysafetyreport/permissions');
  tearDown(() {
    PrefsInbox.useNativeBridgeForTest = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  setUp(
    () => SharedPreferences.setMockInitialValues({key: 'SPP-2610-1234567'}),
  );
  test(
    'lost ACK retries same ID and removes only after matching acceptance',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final ids = <Object?>[];
      var first = true;
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v1/crawl/notification');
        final body = jsonDecode(request.body) as Map;
        ids.add(body['request_id']);
        if (first) {
          first = false;
          throw http.ClientException('lost response');
        }
        return http.Response(
          jsonEncode({'status': 'accepted', 'request_id': key}),
          200,
        );
      });
      Future<void> drain() => drainClientNotifications(
        prefs,
        baseUrl: 'http://fixture',
        apiKey: 'fixture',
        client: client,
        checkScope: () async {},
      );
      await expectLater(drain(), throwsA(isA<http.ClientException>()));
      expect(prefs.containsKey(key), isTrue);
      await drain();
      expect(ids, [key, key]);
      expect(prefs.containsKey(key), isFalse);
    },
  );
  test('구형 서버 응답 유실은 앱 재시작과 경로 캐시 만료 뒤에도 다시 POST하지 않는다', () async {
    final prefs = await SharedPreferences.getInstance();
    var legacyCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/notification')) {
        return http.Response('', 404);
      }
      legacyCalls++;
      throw http.ClientException('accepted but response lost');
    });
    Future<void> drain() => drainClientNotifications(
      prefs,
      baseUrl: 'http://fixture',
      apiKey: 'fixture',
      client: client,
      checkScope: () async {},
    );
    await drain();
    await prefs.remove('crawl_notification_unsupported_at');
    await drain();
    expect(legacyCalls, 1);
    expect(prefs.containsKey(key), isTrue, reason: '미확정 결과를 성공 ACK로 처리하지 않는다');
  });

  test('미확정 구형 요청은 보존하면서 뒤의 새 알림은 처리한다', () async {
    const later = '${key}1';
    SharedPreferences.setMockInitialValues({
      key: 'SPP-2610-1234567',
      'crawl_legacy_enqueue_uncertain.$key': true,
      later: 'SPP-2610-7654321',
    });
    final prefs = await SharedPreferences.getInstance();
    final requests = <String>[];
    await drainClientNotifications(
      prefs,
      baseUrl: 'http://fixture',
      apiKey: 'fixture',
      checkScope: () async {},
      client: MockClient((request) async {
        final id = (jsonDecode(request.body) as Map)['request_id'] as String;
        requests.add(id);
        return http.Response(
          jsonEncode({'status': 'accepted', 'request_id': id}),
          200,
        );
      }),
    );
    expect(requests, [later]);
    expect(prefs.containsKey(key), isTrue);
    expect(prefs.containsKey(later), isFalse);
  });

  test('미확정 200건만 남으면 정상 종료하고 다음 새 알림을 처리한다', () async {
    final uncertainKeys = List.generate(200, (i) => '$key-$i');
    SharedPreferences.setMockInitialValues({
      for (final id in uncertainKeys) id: 'SPP-2610-1234567',
      for (final id in uncertainKeys)
        'crawl_legacy_enqueue_uncertain.$id': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final requests = <String>[];
    Future<void> drain() => drainClientNotifications(
      prefs,
      baseUrl: 'http://fixture',
      apiKey: 'fixture',
      checkScope: () async {},
      client: MockClient((request) async {
        final id = (jsonDecode(request.body) as Map)['request_id'] as String;
        requests.add(id);
        return http.Response(
          jsonEncode({'status': 'accepted', 'request_id': id}),
          200,
        );
      }),
    );
    await drain();
    const fresh = '$key-fresh';
    await prefs.setString(fresh, 'SPP-2610-7654321');
    await drain();
    await drain();
    expect(requests, [fresh]);
    expect(prefs.containsKey(fresh), isFalse);
    for (final id in uncertainKeys) {
      expect(prefs.containsKey(id), isTrue);
      expect(prefs.getBool('crawl_legacy_enqueue_uncertain.$id'), isTrue);
    }
  });

  test('처리 중 구형 응답을 잃어도 다음 알림 처리와 작업 완료를 막지 않는다', () async {
    const fresh = '${key}1';
    SharedPreferences.setMockInitialValues({
      key: 'SPP-2610-1234567',
      fresh: 'SPP-2610-7654321',
      'crawl_notification_unsupported_base_url': 'http://fixture',
      'crawl_notification_unsupported_at':
          DateTime.now().millisecondsSinceEpoch,
    });
    final prefs = await SharedPreferences.getInstance();
    final numbers = <String>[];
    Future<void> drain() => drainClientNotifications(
      prefs,
      baseUrl: 'http://fixture',
      apiKey: 'fixture',
      checkScope: () async {},
      client: MockClient((request) async {
        final number =
            (jsonDecode(request.body) as Map)['report_number'] as String;
        numbers.add(number);
        if (number == 'SPP-2610-1234567') {
          throw http.ClientException('response lost');
        }
        return http.Response('{}', 200);
      }),
    );
    await drain();
    await drain();
    expect(numbers, ['SPP-2610-1234567', 'SPP-2610-7654321']);
    expect(prefs.containsKey(key), isTrue);
    expect(prefs.getBool('crawl_legacy_enqueue_uncertain.$key'), isTrue);
    expect(prefs.containsKey(fresh), isFalse);
  });

  test(
    'wrong ACK (not a 404) preserves receipt without legacy fallback',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await expectLater(
        drainClientNotifications(
          prefs,
          baseUrl: 'http://fixture',
          apiKey: 'fixture',
          client: MockClient((request) async {
            expect(request.url.path, '/api/v1/crawl/notification');
            return http.Response(
              '{"status":"accepted","request_id":"other"}',
              200,
            );
          }),
          checkScope: () async {},
        ),
        throwsStateError,
      );
      expect(prefs.containsKey(key), isTrue);
    },
  );

  test(
    '404 on the new path falls back to legacy /crawl/enqueue and clears pending',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final paths = <String>[];
      await drainClientNotifications(
        prefs,
        baseUrl: 'http://fixture',
        apiKey: 'fixture',
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/api/v1/crawl/notification') {
            return http.Response('', 404);
          }
          expect(request.url.path, '/api/v1/crawl/enqueue');
          expect(jsonDecode(request.body), {
            'report_number': 'SPP-2610-1234567',
          });
          return http.Response('{"status":"success"}', 200);
        }),
        checkScope: () async {},
      );
      expect(paths, ['/api/v1/crawl/notification', '/api/v1/crawl/enqueue']);
      expect(prefs.containsKey(key), isFalse);
      expect(
        prefs.getString('crawl_notification_unsupported_base_url'),
        'http://fixture',
      );
    },
  );

  test('once a server is remembered as unsupported, later notifications skip '
      'straight to /crawl/enqueue', () async {
    SharedPreferences.setMockInitialValues({
      key: 'SPP-2610-1234567',
      'crawl_notification_unsupported_base_url': 'http://fixture',
      'crawl_notification_unsupported_at':
          DateTime.now().millisecondsSinceEpoch,
    });
    final prefs = await SharedPreferences.getInstance();
    final paths = <String>[];
    await drainClientNotifications(
      prefs,
      baseUrl: 'http://fixture',
      apiKey: 'fixture',
      client: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response('{"status":"success"}', 200);
      }),
      checkScope: () async {},
    );
    expect(paths, ['/api/v1/crawl/enqueue']);
    expect(prefs.containsKey(key), isFalse);
  });

  test(
    'after the retry window elapses the new path is tried again, and success '
    'forgets the old-server memory',
    () async {
      SharedPreferences.setMockInitialValues({
        key: 'SPP-2610-1234567',
        'crawl_notification_unsupported_base_url': 'http://fixture',
        'crawl_notification_unsupported_at': DateTime.now()
            .subtract(const Duration(hours: 7))
            .millisecondsSinceEpoch,
      });
      final prefs = await SharedPreferences.getInstance();
      final paths = <String>[];
      await drainClientNotifications(
        prefs,
        baseUrl: 'http://fixture',
        apiKey: 'fixture',
        client: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.url.path, '/api/v1/crawl/notification');
          return http.Response(
            jsonEncode({'status': 'accepted', 'request_id': key}),
            200,
          );
        }),
        checkScope: () async {},
      );
      expect(paths, ['/api/v1/crawl/notification']);
      expect(prefs.containsKey(key), isFalse);
      expect(
        prefs.containsKey('crawl_notification_unsupported_base_url'),
        isFalse,
        reason: '새 경로가 다시 동작하면 구서버 기억을 지운다',
      );
    },
  );

  test('a crash between a successful legacy enqueue and pending removal does '
      'not resend to the old server', () async {
    SharedPreferences.setMockInitialValues({
      key: 'SPP-2610-1234567',
      'crawl_notification_unsupported_base_url': 'http://fixture',
      'crawl_notification_unsupported_at':
          DateTime.now().millisecondsSinceEpoch,
      'crawl_legacy_enqueue_sent_keys': [key],
      'crawl_legacy_enqueue_uncertain.$key': true,
    });
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    await drainClientNotifications(
      prefs,
      baseUrl: 'http://fixture',
      apiKey: 'fixture',
      client: MockClient((request) async {
        calls++;
        return http.Response('{"status":"success"}', 200);
      }),
      checkScope: () async {},
    );
    expect(calls, 0, reason: '이미 보냈다는 표시가 있으면 다시 보내지 않는다');
    expect(prefs.containsKey('crawl_legacy_enqueue_uncertain.$key'), isFalse);
    expect(prefs.containsKey(key), isFalse);
    expect(
      prefs.getStringList('crawl_legacy_enqueue_sent_keys'),
      isEmpty,
      reason: 'pending 을 지우면 보냄 표시도 같이 지운다',
    );
  });
  test('scope change prevents POST', () async {
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    await expectLater(
      drainClientNotifications(
        prefs,
        baseUrl: 'http://fixture',
        apiKey: 'fixture',
        client: MockClient((_) async {
          calls++;
          return http.Response('', 200);
        }),
        checkScope: () async => throw StateError('changed'),
      ),
      throwsStateError,
    );
    expect(calls, 0);
    expect(prefs.containsKey(key), isTrue);
  });

  for (final quarantined in [false, true]) {
    test(
      'native acceptance ACKs and drains past batch with quarantine=$quarantined',
      () async {
        SharedPreferences.setMockInitialValues({});
        PrefsInbox.useNativeBridgeForTest = true;
        final prefs = await SharedPreferences.getInstance();
        final pending = <String, String>{
          for (var i = 0; i < 25; i++)
            'inbox.enqueue.native.notification.$i': 'SPP-2610-${1234500 + i}',
        };
        final accepted = <String>[];
        final acknowledged = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              final args = call.arguments as Map;
              if (call.method == 'processingInboxRead') {
                expect(args['owner'], isNotEmpty);
                return {
                  'pending': [
                    for (final e in pending.entries)
                      {'key': e.key, 'value': e.value},
                  ],
                  'acknowledged': <String>[],
                  'migrated': <String>[],
                  'blockedScope': quarantined ? 1 : 0,
                  'blockedLegacy': quarantined ? 1 : 0,
                };
              }
              if (call.method == 'processingInboxAck') {
                for (final id in (args['keys'] as List).cast<String>()) {
                  expect(accepted, contains(id));
                  expect(prefs.containsKey(id), isTrue);
                  expect(args['owner'], isNotEmpty);
                  acknowledged.add(id);
                  pending.remove(id);
                }
                return true;
              }
              throw StateError('unexpected ${call.method}');
            });
        Future<void> drain() => drainClientNotifications(
          prefs,
          baseUrl: 'http://fixture',
          apiKey: 'fixture',
          client: MockClient((request) async {
            final id =
                (jsonDecode(request.body) as Map)['request_id'] as String;
            accepted.add(id);
            return http.Response(
              jsonEncode({'status': 'accepted', 'request_id': id}),
              200,
            );
          }),
          checkScope: () async {},
        );
        await drain();
        expect(acknowledged.length, 20);
        await drain();
        await drain();
        expect(pending, isEmpty);
        expect(acknowledged.length, 25);
        expect(accepted.length, 25);
        expect(prefs.getKeys(), isEmpty);
      },
    );
  }

  test('failed native ACK preserves mirror for idempotent retry', () async {
    PrefsInbox.useNativeBridgeForTest = true;
    final prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'processingInboxRead') {
            return {
              'pending': [
                {'key': key, 'value': 'SPP-2610-1234567'},
              ],
              'acknowledged': [],
              'migrated': [],
            };
          }
          return false;
        });
    await expectLater(
      drainClientNotifications(
        prefs,
        baseUrl: 'http://fixture',
        apiKey: 'fixture',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'status': 'accepted', 'request_id': key}),
            200,
          ),
        ),
        checkScope: () async {},
      ),
      throwsStateError,
    );
    expect(prefs.containsKey(key), isTrue);
  });
}
