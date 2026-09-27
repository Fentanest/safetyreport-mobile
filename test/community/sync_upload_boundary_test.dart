import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safetyreport/community/upload/community_uploader.dart';
import 'package:safetyreport/community/upload_hooks.dart';
import 'package:safetyreport/services/sync_engine.dart';
import 'package:safetyreport/services/standalone_auto_sync_service.dart';
import 'package:safetyreport/services/standalone_pending_queue_store.dart';

void main() {
  tearDown(() => CommunityUploadHooks.uploadBeforeSync = null);

  test('이전 업로드가 여러 실행에 걸리면 모두 마친 뒤 동기화를 허용한다', () async {
    var runs = 0;
    CommunityUploadHooks.uploadBeforeSync = () async {
      runs++;
      return (
        run: UploadRunResult(runId: '$runs', result: runs == 1 ? 'more_pending' : 'sent'),
        remaining: runs == 1 ? 2 : 0,
      );
    };
    await SyncEngine.flushPendingUploadBeforeSync();
    expect(runs, 2);
  });

  test('이전 자료가 남으면 새 동기화를 차단하고 원인을 알린다', () async {
    CommunityUploadHooks.uploadBeforeSync = () async => (
          run: const UploadRunResult(runId: 'failed', result: 'cooldown', errorCode: 'offline'),
          remaining: 3,
        );
    await expectLater(SyncEngine.flushPendingUploadBeforeSync(),
        throwsA(predicate((e) => '$e'.contains('3건') && '$e'.contains('offline'))));
  });

  test('개별 동기화도 이전 업로드 실패 시 신고 큐를 그대로 둔다', () async {
    SharedPreferences.setMockInitialValues({});
    await StandalonePendingQueueStore.append(['R1']);
    CommunityUploadHooks.uploadBeforeSync = () async => (
          run: const UploadRunResult(runId: 'failed', result: 'cooldown', errorCode: 'offline'),
          remaining: 1,
        );
    await StandaloneAutoSyncService.drainIfPending();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(StandalonePendingQueueStore.read(prefs), ['R1']);
  });
}
