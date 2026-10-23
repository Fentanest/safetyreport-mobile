import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/community/community_wiring.dart';
import 'package:safetyreport/community/manifest_result.dart';
import 'package:safetyreport/community/upload/community_ingest_client.dart';
import 'package:safetyreport/community/upload_pause.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory tmp;
  late CommunityStore store;
  late String path;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('manifest-recovery-');
    path = '${tmp.path}/community.db';
    store = await CommunityStore.open(path: path, factory: databaseFactoryFfi);
    UploadPause.current.value = null;
  });
  tearDown(() async {
    UploadPause.current.value = null;
    await CommunityStore.closeForTest(path);
    await tmp.delete(recursive: true);
  });

  Future<void> activate() => store.setContext({
    'dataset_key': 'dataset',
    'connection_id': 'connection',
    'writer_epoch': 1,
    'contributor_fingerprint': 'synthetic',
    'consent_grant_id': 'grant',
  });
  Map<String, Object?> page({int total = 0, String dataset = 'dataset'}) => {
    'protocol': 1,
    'dataset_key': dataset,
    'writer_epoch': 1,
    'total': total,
    'manifest_token': '1',
    'key_prefixes': <String>[],
    'next_after': null,
  };
  CommunityIngestClient client(
    Future<http.Response> Function(http.Request) handler,
  ) => CommunityIngestClient(
    supabaseUrl: 'https://synthetic.invalid',
    publishableKey: 'synthetic',
    httpClient: MockClient(handler),
  );

  test(
    'busy upload makes no HTTP request, releases no uploader lease, then succeeds',
    () async {
      await activate();
      var requests = 0;
      final c = client((_) async {
        requests++;
        return http.Response(jsonEncode(page()), 200);
      });
      await store.acquireLease(
        'upload',
        'uploader',
        const Duration(minutes: 5),
      );
      final busy = await CommunityWiring.refreshManifest(
        store,
        client: c,
        token: () async => 'token',
      );
      expect(busy.status, ManifestStatus.busyUploadLease);
      expect(requests, 0);
      expect((await store.db.query('leases')).single['owner'], 'uploader');
      expect(await store.meta('manifest_scope'), isNull);
      await store.releaseLease('upload', 'uploader');
      expect(
        (await CommunityWiring.refreshManifest(
          store,
          client: c,
          token: () async => 'token',
        )).isOk,
        isTrue,
      );
      expect(requests, 1);
      expect(await store.meta('manifest_scope'), 'dataset:1');
      expect(await store.db.query('leases'), isEmpty);
    },
  );

  test(
    'no context, no token and pause are distinct and never request HTTP',
    () async {
      final c = client((_) async => throw StateError('must not request'));
      expect(
        (await CommunityWiring.refreshManifest(
          store,
          client: c,
          token: () async => 't',
        )).status,
        ManifestStatus.noContext,
      );
      await activate();
      expect(
        (await CommunityWiring.refreshManifest(
          store,
          client: c,
          token: () async => null,
        )).status,
        ManifestStatus.noToken,
      );
      await UploadPause.applyMaintenance(store, {'code': 'maintenance'});
      expect(
        (await CommunityWiring.refreshManifest(
          store,
          client: c,
          token: () async => 't',
        )).status,
        ManifestStatus.paused,
      );
    },
  );

  for (final (httpStatus, code, expected) in [
    (401, 'auth_required', ManifestStatus.auth),
    (403, 'session_expired', ManifestStatus.auth),
    (403, 'consent_required', ManifestStatus.consentRequired),
    (403, 'consent_missing', ManifestStatus.consentRequired),
    (403, 'consent_grant_unknown', ManifestStatus.consentRequired),
    (403, 'writer_superseded', ManifestStatus.writerRequired),
    (403, 'connection_session_mismatch', ManifestStatus.noContext),
    (409, 'policy_mismatch', ManifestStatus.consentRequired),
    (409, 'connection_superseded', ManifestStatus.writerRequired),
    (429, 'too_many_requests', ManifestStatus.rateLimited),
    (503, 'maintenance', ManifestStatus.paused),
    (500, 'internal_error', ManifestStatus.serverError),
  ]) {
    test('HTTP $httpStatus / $code retains diagnostic fields', () async {
      final c = client(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': code,
              'request_id': 'request-252',
              'message': 'private text',
            },
          }),
          httpStatus,
        ),
      );
      final result = await c.fetchManifestPage('token', 'connection');
      expect(result.status, expected);
      expect(result.httpStatus, httpStatus);
      expect(result.serverCode, code);
      expect(result.requestId, 'request-252');
      expect(jsonEncode(result.diagnostics), isNot(contains('private text')));
      expect(result.page, isNull);
    });
  }

  test(
    'non JSON 5xx remains temporary; malformed 200 is invalid; socket is network',
    () async {
      for (final (response, expected) in [
        (
          http.Response('<html>bad gateway</html>', 502),
          ManifestStatus.serverError,
        ),
        (http.Response('not JSON', 200), ManifestStatus.invalidResponse),
        (http.Response('{}', 200), ManifestStatus.invalidResponse),
      ]) {
        expect(
          (await client(
            (_) async => response,
          ).fetchManifestPage('t', 'c')).status,
          expected,
        );
      }
      expect(
        (await client(
          (_) async => throw const SocketException('offline'),
        ).fetchManifestPage('t', 'c')).status,
        ManifestStatus.network,
      );
    },
  );

  test(
    'cross-page integrity rejection preserves previous completed list and HTTP metadata',
    () async {
      await activate();
      await store.db.insert('server_completed', {
        'dataset_key': 'dataset',
        'key_prefix': 'old',
        'fetched_at': isoUtc(DateTime.now()),
      });
      for (final body in [page(total: 1), page(dataset: 'other-dataset')]) {
        final result = await CommunityWiring.refreshManifest(
          store,
          client: client(
            (_) async => http.Response(
              jsonEncode(body),
              200,
              headers: {'x-request-id': 'integrity-252'},
            ),
          ),
          token: () async => 't',
        );
        expect(result.status, ManifestStatus.invalidResponse);
        expect(result.httpStatus, 200);
        expect(result.requestId, 'integrity-252');
        expect(
          (await store.db.query('server_completed')).single['key_prefix'],
          'old',
        );
        expect(await store.meta('manifest_scope'), isNull);
      }
    },
  );

  test('maintenance persistence exception retains HTTP diagnosis', () async {
    final c = client(
      (_) async => http.Response(
        jsonEncode({
          'error': {'code': 'maintenance', 'request_id': 'pause-252'},
        }),
        503,
      ),
    );
    final result = await c.fetchManifestPage(
      't',
      'c',
      onMaintenance: (_) async => throw StateError('local write failed'),
    );
    expect(result.status, ManifestStatus.paused);
    expect(result.httpStatus, 503);
    expect(result.requestId, 'pause-252');
  });

  test(
    'upload lease loss at commit preserves HTTP diagnosis and refuses replacement',
    () async {
      await activate();
      final result = await CommunityWiring.refreshManifest(
        store,
        client: client((_) async {
          await store.db.delete(
            'leases',
            where: 'name=?',
            whereArgs: ['upload'],
          );
          return http.Response(
            jsonEncode(page()),
            200,
            headers: {'x-request-id': 'lease-252'},
          );
        }),
        token: () async => 't',
      );
      expect(result.status, ManifestStatus.busyUploadLease);
      expect(result.httpStatus, 200);
      expect(result.requestId, 'lease-252');
      expect(await store.meta('manifest_scope'), isNull);
    },
  );

  test('context change during HTTP cannot replace completed list', () async {
    await activate();
    final result = await CommunityWiring.refreshManifest(
      store,
      client: client((_) async {
        await store.deactivateContext('logout');
        return http.Response(
          jsonEncode(page()),
          200,
          headers: {'x-request-id': 'context-252'},
        );
      }),
      token: () async => 't',
    );
    expect(result.status, ManifestStatus.noContext);
    expect(result.httpStatus, 200);
    expect(result.requestId, 'context-252');
    expect(await store.meta('manifest_scope'), isNull);
  });
}
