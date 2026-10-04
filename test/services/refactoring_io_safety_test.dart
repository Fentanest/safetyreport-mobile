import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:safetyreport/community/capture/capture_retry_store.dart';
import 'package:safetyreport/services/attachment_cache.dart';
import 'package:safetyreport/services/pending_changes_store.dart';
import 'package:safetyreport/services/prefs_inbox.dart';
import 'package:safetyreport/services/standalone_pending_queue_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StallClient extends http.BaseClient {
  final stream = StreamController<List<int>>();
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream.stream, 200);
  @override
  void close() {
    closed = true;
    unawaited(stream.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sr_refactor_io_');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'filename, origin and scope do not identify the same attachment',
    () async {
      Future<File> get(String url, String scope) => AttachmentCache.fetch(
        root: root,
        uri: Uri.parse(url),
        scope: scope,
        isCancelled: () => false,
        clientFactory: () => MockClient(
          (request) async => http.Response('$scope:${request.url}', 200),
        ),
      );
      final a = await get('https://a.test/a.pdf', 'owner-a');
      final b = await get('https://b.test/a.pdf', 'owner-a');
      final c = await get('https://a.test/a.pdf', 'owner-b');
      expect({a.path, b.path, c.path}, hasLength(3));
      expect(await a.readAsString(), 'owner-a:https://a.test/a.pdf');
      expect(await b.readAsString(), 'owner-a:https://b.test/a.pdf');
      expect(await c.readAsString(), 'owner-b:https://a.test/a.pdf');
    },
  );

  test('concurrent downloads return their own immutable bytes', () async {
    Future<File> get(String content, int delay) => AttachmentCache.fetch(
      root: root,
      uri: Uri.parse('https://fixture.test/a.pdf'),
      scope: 'same-owner',
      isCancelled: () => false,
      clientFactory: () => MockClient((_) async {
        await Future<void>.delayed(Duration(milliseconds: delay));
        return http.Response(content, 200);
      }),
    );
    final files = await Future.wait([get('first', 30), get('second', 5)]);
    expect(await files[0].readAsString(), 'first');
    expect(await files[1].readAsString(), 'second');
    expect(
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  });

  test(
    'conditional cache uses validated content; remote updates are revalidated',
    () async {
      final uri = Uri.parse('https://fixture.test/a.pdf');
      final first = await AttachmentCache.fetch(
        root: root,
        uri: uri,
        scope: 'owner',
        isCancelled: () => false,
        clientFactory: () => MockClient(
          (_) async =>
              http.Response('version-one', 200, headers: {'etag': 'one'}),
        ),
      );
      final same = await AttachmentCache.fetch(
        root: root,
        uri: uri,
        scope: 'owner',
        isCancelled: () => false,
        clientFactory: () => MockClient((r) async {
          expect(r.headers['If-None-Match'], 'one');
          return http.Response('', 304);
        }),
      );
      expect(same.path, first.path);
      final second = await AttachmentCache.fetch(
        root: root,
        uri: uri,
        scope: 'owner',
        isCancelled: () => false,
        clientFactory: () => MockClient(
          (_) async =>
              http.Response('version-two', 200, headers: {'etag': 'two'}),
        ),
      );
      expect(await second.readAsString(), 'version-two');
      expect(await first.readAsString(), 'version-one');
    },
  );

  test(
    'a stalled response closes its transport and publishes no file',
    () async {
      final client = StallClient();
      await expectLater(
        AttachmentCache.fetch(
          root: root,
          uri: Uri.parse('https://fixture.test/a.pdf'),
          scope: 'owner',
          isCancelled: () => false,
          clientFactory: () => client,
          deadline: const Duration(milliseconds: 40),
        ),
        throwsA(anyOf(isA<AttachmentCancelled>(), isA<TimeoutException>())),
      );
      expect(client.closed, isTrue);
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

  test(
    'concurrent retry mutations across isolates preserve every obligation',
    () async {
      final path = '${root.path}/retry.json';
      await Future.wait(
        List.generate(
          4,
          (worker) => Isolate.run(() async {
            final file = File(path);
            for (var i = 0; i < 20; i++) {
              await CaptureRetryStore.addIntent(file, '$worker:$i', 'fixture');
            }
          }),
        ),
      );
      final ids = await CaptureRetryStore.captureRetryIds(File(path));
      expect(ids, hasLength(80));
      await Future.wait(
        ids
            .take(40)
            .map((id) => CaptureRetryStore.removeIntent(File(path), id)),
      );
      expect(
        await CaptureRetryStore.captureRetryIds(File(path)),
        ids.skip(40).toSet(),
      );
      expect(
        Directory('$path.events-v1').listSync().whereType<File>(),
        hasLength(40),
        reason: 'terminal receipts retire only after their observed adds',
      );
    },
  );

  test('a corrupt ACK cannot retire another report obligation', () async {
    final file = File('${root.path}/retry.json');
    await CaptureRetryStore.addIntent(file, 'retained-report', 'fixture');
    final events = Directory('${file.path}.events-v1');
    final add = events.listSync().whereType<File>().single;
    final addId = (jsonDecode(await add.readAsString()) as Map)['event_id'];
    const ackId = '11111111-1111-4111-8111-111111111111';
    await File('${events.path}/$ackId.json').writeAsString(
      jsonEncode({
        'format_version': 1,
        'kind': 'ack',
        'event_id': ackId,
        'source_report_id': 'different-report',
        'observed': [addId],
      }),
    );
    await expectLater(
      CaptureRetryStore.addIntent(file, 'new-report', 'fixture'),
      throwsFormatException,
    );
    expect(await add.exists(), isTrue);
  });

  test('a corrupt legacy retry file is retained and blocks capture', () async {
    final file = File('${root.path}/retry.json');
    await file.writeAsString('{broken');
    await expectLater(
      CaptureRetryStore.addIntent(file, 'R1', 'fixture'),
      throwsFormatException,
    );
    expect(await file.readAsString(), '{broken');
  });

  test(
    'claim ACK preserves a newer event with the same report number',
    () async {
      await StandalonePendingQueueStore.append(['SPP-1']);
      final prefs = await SharedPreferences.getInstance();
      final claim = StandalonePendingQueueStore.claim(prefs)!;
      await StandalonePendingQueueStore.append(['SPP-1']);
      await StandalonePendingQueueStore.acknowledge(prefs, claim);
      expect(StandalonePendingQueueStore.read(prefs), ['SPP-1']);
      expect(
        prefs.getKeys().where((k) => k.startsWith(PrefsInbox.queue)),
        hasLength(1),
      );
    },
  );

  test(
    'processing obligations exceed history retention without eviction',
    () async {
      await StandalonePendingQueueStore.append(
        List.generate(201, (i) => 'SPP-$i'),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(StandalonePendingQueueStore.read(prefs), hasLength(201));
    },
  );

  test(
    'pending changes are non-destructive until the receiver acknowledges',
    () async {
      await PendingChangesStore.append([
        {'ID': '001', '신고명': '한글'},
      ]);
      final first = await PendingChangesStore.readPending();
      expect((await PendingChangesStore.readPending()).items, first.items);
      await PendingChangesStore.append([
        {'ID': '002'},
      ]);
      await PendingChangesStore.acknowledge(first);
      expect((await PendingChangesStore.readPending()).items, [
        {'ID': '002'},
      ]);
    },
  );

  test('corrupt pending changes retain the legacy source', () async {
    SharedPreferences.setMockInitialValues({
      'pending_crawl_changes': '{broken',
    });
    await expectLater(PendingChangesStore.readPending(), throwsFormatException);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'pending_crawl_changes',
      ),
      '{broken',
    );
  });
}
