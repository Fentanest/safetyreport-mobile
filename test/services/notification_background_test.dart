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
  test(
    'old server and wrong ACK preserve receipt without legacy fallback',
    () async {
      final prefs = await SharedPreferences.getInstance();
      for (final response in [
        http.Response('', 404),
        http.Response('{"status":"accepted","request_id":"other"}', 200),
      ]) {
        await expectLater(
          drainClientNotifications(
            prefs,
            baseUrl: 'http://fixture',
            apiKey: 'fixture',
            client: MockClient((request) async {
              expect(request.url.path, '/api/v1/crawl/notification');
              return response;
            }),
            checkScope: () async {},
          ),
          throwsStateError,
        );
        expect(prefs.containsKey(key), isTrue);
      }
    },
  );
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
