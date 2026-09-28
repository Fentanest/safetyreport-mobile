// 동기화 로그의 10건 단위 'N/M건 전송' 줄: 이번 실행 이벤트 중 ACK 수 / 업로드 대상(outbox 또는 ACK) 수.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late CommunityStore store;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sr_upload_progress_');
    store = await CommunityStore.open(path: '${dir.path}/community.db', factory: databaseFactoryFfi);
  });
  tearDown(() async {
    await store.db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> journal(String id, int revision, {String? ackedAt, bool outbox = false}) async {
    await store.db.insert('source_journal', {
      'event_id': id, 'project_namespace': 'ns', 'local_dataset_id': 'd1', 'source_report_id': 'R$revision',
      'source_revision': revision, 'event_type': 'observed', 'captured_at': '2026-09-28T00:00:00.000Z',
      'capture_trigger': 'realtime', 'schema_version': 1, 'parser_version': 'p1', 'payload_json': '{}',
      'payload_sha256': 'h', 'eligible': 1, 'acked_at': ackedAt,
    });
    if (outbox) {
      await store.db.insert('outbox', {
        'event_id': id, 'state': 'pending', 'enqueued_trigger': 'realtime', 'enqueued_at': '2026-09-28T00:00:00.000Z',
      });
    }
  }

  Future<List<String>> logsOf(Future<void> Function() body) async {
    final logs = <String>[];
    final sub = SyncEngine.events.where((e) => e.type == SyncEventType.log).listen((e) => logs.add(e.message));
    await body();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    return logs;
  }

  test('ACK 된 수 / 업로드 대상 수를 한 줄로 적고, 대상이 아닌 이벤트는 세지 않는다', () async {
    await journal('e1', 1, ackedAt: '2026-09-28T00:00:01.000Z');
    await journal('e2', 2, outbox: true);
    await journal('e3', 3); // 공유 연결이 비활성일 때의 캡처 — outbox 없음
    final logs = await logsOf(() => SyncEngine.logUploadProgress(store, ['e1', 'e2', 'e3']));
    expect(logs, ['1/2건 전송']);
  });

  test('업로드 대상이 없거나 저장소가 없으면 출력하지 않는다', () async {
    await journal('e3', 3);
    expect(await logsOf(() => SyncEngine.logUploadProgress(store, ['e3'])), isEmpty);
    expect(await logsOf(() => SyncEngine.logUploadProgress(null, ['e3'])), isEmpty);
    expect(await logsOf(() => SyncEngine.logUploadProgress(store, [])), isEmpty);
  });

  test('SQLite 변수 한도를 넘는 이벤트 수도 나눠서 센다', () async {
    final ids = <String>[];
    for (var i = 1; i <= 1200; i++) {
      await journal('e$i', i, ackedAt: i.isEven ? '2026-09-28T00:00:01.000Z' : null, outbox: i.isOdd);
      ids.add('e$i');
    }
    expect(await logsOf(() => SyncEngine.logUploadProgress(store, ids)), ['600/1200건 전송']);
  });
}
