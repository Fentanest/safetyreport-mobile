// 기존 신고 다시 보내기(크롤링 없음) — fine-estimate-contract.md "기존 신고 다시 보내기".
//
// 이미 공유한 신고의 journal 최신 payload에서 fine_estimate만 다시 계산한다.
// 개인 DB는 추정 입력만 제공하고, 답변·확정 금액 등 나머지 필드는 journal 그대로 보존한다.
// 변경이 없으면 이벤트를 만들지 않는다. 동의·계정 문맥의 전송 제약은 capture()를 따른다.
//
// 앱 업데이트 뒤 Standalone 게이트 통과 때 1회(ReportProvider.onGatePassed). 완료 표시는
// (rule_version, parser_version) 기준 — 둘 중 하나라도 바뀌면 다시 돈다. 중간에 멈추면(DB 닫힘,
// capture 실패 등) 커서를 남겨 다음 실행이 이어간다. Client 모드는 PC 서버가 올리므로 호출하지
// 않는다(ReportProvider 쪽에서 Standalone 일 때만 부른다).

import '../../services/community_auth_config.dart';
import '../../services/fine_estimate.dart' as fine_estimate;
import '../../services/local_db_service.dart';
import '../../services/sync_operation_admission.dart';
import '../community_store.dart';
import '../upload_hooks.dart';
import 'community_capture.dart';

const String _metaDoneKey = 'fine_estimate_resend_done';
const String _metaCursorKey = 'fine_estimate_resend_cursor';
const String _metaCursorVersionKey = 'fine_estimate_resend_cursor_version';
const int _batchSize = 200;

String _targetVersion() => '${fine_estimate.ruleVersion}|$mobileParserVersion';

/// 개인 DB에서는 추정 판정에 필요한 입력만 전달한다.
Map<String, Object?> adapterInputFromResendRow(Map<String, Object?> row) => {
  'entry_value': row['entry_value'],
  'ssnpc_cd': row['ssnpc_cd'],
  'ssnpc_type': row['ssnpc_type'],
  'car_number': row['차량번호'],
  'report_name': row['신고명'],
  'occurrence_time': row['발생시각'],
  'photo_first_capture': row['사진_첫촬영'],
  'photo_last_capture': row['사진_끝촬영'],
};

/// 이미 이 (rule_version, parser_version) 로 끝났으면 바로 반환(0). 아니면 ID 오름차순으로
/// 기존에 한 번이라도 적격 캡처된 신고(`report_latest`)를 훑어 capture() 를 다시 돌린다.
/// 반환값 = 새 이벤트를 만든(=payload 가 바뀐) 신고 수.
Future<int> resendFineEstimateIfNeeded({CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  final target = _targetVersion();
  if (await s.meta(_metaDoneKey) == target) return 0;

  // Keep the personal DB file alive while the shared sync lease covers the snapshot.
  return LocalDbService.runBackgroundWork(
    () => SyncOperationAdmission.run(
      () async {
        var resent = 0;
        // 업로더가 현재 네임스페이스와 같은 journal 행만 올린다(community_uploader.dart) — 실시간
        // capture() 와 같은 방식으로 구해야 재전송분이 outbox 에 쌓인 채 영영 안 올라가지 않는다.
        var ns = 'unconfigured';
        try {
          ns = projectNamespace(
            CommunityAuthConfig.fromEnvironment.supabaseUrl,
          );
        } catch (_) {}
        final datasetId = await s.localDatasetId();
        final cursorVersion = await s.meta(_metaCursorVersionKey);
        var afterId = cursorVersion == target
            ? (await s.meta(_metaCursorKey) ?? '')
            : ''; // 버전이 바뀌었으면 이전 커서는 의미가 없다 — 처음부터.

        while (true) {
          if (LocalDbService.closeRequested) return resent;
          await SyncOperationAdmission.checkOwnership();
          final idRows = await s.db.rawQuery(
            'SELECT l.source_report_id FROM report_latest l '
            'JOIN source_journal j ON j.event_id=l.event_id '
            "WHERE l.local_dataset_id=? AND l.source_report_id>? AND "
            "(j.blocked_reason IS NULL OR j.blocked_reason!='deleted_by_user') "
            'ORDER BY l.source_report_id LIMIT ?',
            [datasetId, afterId, _batchSize],
          );
          if (idRows.isEmpty) break;
          final batchIds = [
            for (final r in idRows) r['source_report_id'] as String,
          ];
          final rows = await LocalDbService.communityResendRows(batchIds);
          final byId = {for (final r in rows) r['ID'] as String: r};

          for (final id in batchIds) {
            final row = byId[id];
            if (row != null) {
              try {
                final cap = await capture(
                  adapterInputFromResendRow(row),
                  sourceReportId: id,
                  trigger: 'fine_estimate_resend',
                  store: s,
                  projectNamespace: ns,
                  beforeWrite: (tx) =>
                      SyncOperationAdmission.checkOwnership(executor: tx),
                );
                if (cap.eventId != null) resent++;
              } catch (_) {
                // 이 신고에서 멈춘다 — 다음 실행이 같은 커서(이 ID 이전)부터 다시 본다.
                await s.setMeta(_metaCursorKey, afterId);
                await s.setMeta(_metaCursorVersionKey, target);
                return resent;
              }
            }
            afterId = id;
          }
          await s.setMeta(_metaCursorKey, afterId);
          await s.setMeta(_metaCursorVersionKey, target);
        }
        await s.transaction((tx) async {
          await SyncOperationAdmission.checkOwnership(executor: tx);
          await s.setMeta(_metaDoneKey, target, tx);
        });
        if (resent > 0) {
          CommunityUploadHooks.wakeUploadNow('fine_estimate_resend');
        }
        return resent;
      },
      0,
      openStore: () async => s,
      stopRequested: () => LocalDbService.closeRequested,
    ),
  );
}
