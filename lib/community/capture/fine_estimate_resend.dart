// 기존 신고 다시 보내기(크롤링 없음) — fine-estimate-contract.md "기존 신고 다시 보내기".
//
// fine_estimate(observation-v5(fine_estimate 추가)) 추가 뒤, 이미 커뮤니티에 올라간 적 있는 기존 신고의 payload 를
// 로컬 personal DB 값으로 다시 만들어 본다(공식 사이트를 다시 읽지 않음). payload_sha256 이
// 바뀐 것(=추정 필드가 새로 생긴 것)만 기존 capture()(journal/outbox) 경로로 다시 보낸다 — 대상이
// 아니면 capture() 가 그대로 이벤트 없음을 돌려준다(기존 decideEvent 규칙, 여기서 새로 판단하지
// 않음). 동의·계정 문맥이 없거나 철회됐으면 capture() 가 이미 outbox 전송을 막는다(기존 규칙).
//
// 앱 업데이트 뒤 Standalone 게이트 통과 때 1회(ReportProvider.onGatePassed). 완료 표시는
// (rule_version, parser_version) 기준 — 둘 중 하나라도 바뀌면 다시 돈다. 중간에 멈추면(DB 닫힘,
// capture 실패 등) 커서를 남겨 다음 실행이 이어간다. Client 모드는 PC 서버가 올리므로 호출하지
// 않는다(ReportProvider 쪽에서 Standalone 일 때만 부른다).
import 'dart:async';

import '../../services/community_auth_config.dart';
import '../../services/fine_estimate.dart' as fine_estimate;
import '../../services/local_db_service.dart';
import '../community_store.dart';
import '../upload_hooks.dart';
import 'community_capture.dart';

const String _lease = 'fine_estimate_resend';
const String _metaDoneKey = 'fine_estimate_resend_done';
const String _metaCursorKey = 'fine_estimate_resend_cursor';
const String _metaCursorVersionKey = 'fine_estimate_resend_cursor_version';
const int _batchSize = 200;

String _targetVersion() => '${fine_estimate.ruleVersion}|$mobileParserVersion';

String _str(Object? v) => v?.toString() ?? '';

double? _toDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v == null) return null;
  return double.tryParse(v.toString());
}

int? _toRating(Object? v) {
  if (v is int) return v;
  if (v == null) return null;
  return int.tryParse(v.toString());
}

/// 로컬 personal DB 행(`LocalDbService.communityResendRows`) → capture() 입력. 열 이름은
/// local_statistics.dart·fine_estimate.dart 와 같다(observation.md 2절 모바일 열과 동의어).
Map<String, Object?> adapterInputFromResendRow(Map<String, Object?> row) {
  final lat = _toDouble(row['위도']);
  final lng = _toDouble(row['경도']);
  final located =
      lat != null &&
      lng != null &&
      lat.isFinite &&
      lng.isFinite &&
      lat >= 32 &&
      lat <= 39.5 &&
      lng >= 124 &&
      lng <= 132;
  return buildAdapterInput(
    status: _str(row['처리상태'] ?? row['상태']),
    reportNumber: row['신고번호']?.toString(),
    fineInfo: _str(row['범칙금_과태료']),
    date: _str(row['신고일']),
    responseDate: _str(row['답변일']),
    agency: _str(row['처리기관']),
    agencyCode: row['처리기관코드']?.toString(),
    manager: _str(row['담당자']),
    carNumber: _str(row['차량번호']),
    location: _str(row['위반장소']),
    penaltyPoints: _str(row['벌점']),
    entryValue: _str(row['entry_value']),
    ssnpcCd: row['ssnpc_cd']?.toString(),
    ssnpcType: row['ssnpc_type']?.toString(),
    violationLaw: _str(row['위반법규']),
    rating: _toRating(row['별점']),
    geo: located ? GeocodeHit(status: 'ok', lat: lat, lng: lng) : null,
    progressStatus: _str(row['상태']),
    category: row['category']?.toString(),
    reportName: _str(row['신고명']),
    occurrenceTime: _str(row['발생시각']),
    photoFirstCapture: row['사진_첫촬영']?.toString(),
    photoLastCapture: row['사진_끝촬영']?.toString(),
  );
}

/// 이미 이 (rule_version, parser_version) 로 끝났으면 바로 반환(0). 아니면 ID 오름차순으로
/// 기존에 한 번이라도 적격 캡처된 신고(`report_latest`)를 훑어 capture() 를 다시 돌린다.
/// 반환값 = 새 이벤트를 만든(=payload 가 바뀐) 신고 수.
Future<int> resendFineEstimateIfNeeded({CommunityStore? store}) async {
  final s = store ?? await CommunityStore.open();
  final target = _targetVersion();
  if (await s.meta(_metaDoneKey) == target) return 0;

  final owner = newUuidV4();
  if (!await s.acquireLease(_lease, owner, const Duration(minutes: 10))) {
    return 0; // 다른 실행(다른 isolate 포함)이 이미 돌고 있다 — 그 실행이 끝에서 완료 표시를 남긴다.
  }
  final heartbeat = Timer.periodic(const Duration(minutes: 1), (_) {
    unawaited(s.renewLease(_lease, owner, const Duration(minutes: 10)));
  });
  var resent = 0;
  try {
    // 업로더가 현재 네임스페이스와 같은 journal 행만 올린다(community_uploader.dart) — 실시간
    // capture() 와 같은 방식으로 구해야 재전송분이 outbox 에 쌓인 채 영영 안 올라가지 않는다.
    var ns = 'unconfigured';
    try {
      ns = projectNamespace(CommunityAuthConfig.fromEnvironment.supabaseUrl);
    } catch (_) {}
    final datasetId = await s.localDatasetId();
    final cursorVersion = await s.meta(_metaCursorVersionKey);
    var afterId = cursorVersion == target
        ? (await s.meta(_metaCursorKey) ?? '')
        : ''; // 버전이 바뀌었으면 이전 커서는 의미가 없다 — 처음부터.

    while (true) {
      if (LocalDbService.closeRequested) return resent;
      final idRows = await s.db.rawQuery(
        'SELECT source_report_id FROM report_latest '
        'WHERE local_dataset_id=? AND source_report_id>? '
        'ORDER BY source_report_id LIMIT ?',
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
    await s.setMeta(_metaDoneKey, target);
    if (resent > 0) CommunityUploadHooks.wakeUploadNow('fine_estimate_resend');
    return resent;
  } finally {
    heartbeat.cancel();
    await s.releaseLease(_lease, owner);
  }
}
