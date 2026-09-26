import 'dart:async';

import 'gate/community_account_client.dart';

/// T6(모바일 데이터 경로) 연결 자리 (`contracts/community-ingest/interfaces.md`).
///
/// T6 병합 전까지는 기본값(아래)이 쓰인다. T6 는 같은 이름·시그니처의 실제 구현으로
/// 이 필드를 채우거나(Opus 통합) 이 파일을 실제 모듈로 교체한다.
/// 자세한 요청은 `.agent-runs/T5/REQUESTS.md`.
class CommunityUploadHooks {
  CommunityUploadHooks._();

  /// `community-ingest/manifest` 전 페이지로 `server_completed` 교체 + `meta.manifest_scope` 기록.
  /// false 면 수집·초기화를 시작하지 않는다.
  /// T6 미병합 기본값: 연결이 없으므로 교체할 manifest 가 없어 `true`(게이트·연결 등록 흐름 차단 안 함).
  static Future<bool> Function()? refreshServerCompleted;

  /// T6 `registerBackgroundJobs()` — 자정·주기 업로드 작업 등록.
  static Future<void> Function()? registerBackgroundJobs;

  /// T6 `catchUp(reason)` — resume·시작 시 보충 실행.
  static Future<void> Function(String reason)? catchUp;

  /// T6 `onContributionsDeleted()` — 공유 자료 삭제 성공 뒤 대기 행 차단.
  static Future<void> Function()? onContributionsDeleted;

  /// 중앙 삭제 요청 **전** 로컬 삭제 대기 표시(community.db). 실패하면 중앙 삭제를 요청하지 않는다(Sol 2차 H-03a).
  static Future<String> Function()? beginDeletion;

  /// 중앙 삭제가 확실히 실패했을 때 그 표시 하나를 지운다.
  static Future<void> Function(String id)? cancelDeletion;

  /// 중앙 삭제 성공 뒤 모든 표시를 확정·적용한다.
  static Future<void> Function()? confirmDeletion;

  /// 공유 자료 삭제 요청 순서(PC 라우트와 같음): prepared 표시 → 중앙 삭제 → 성공이면 확정·적용.
  /// 반환: 'not_started'(표시를 못 써 중앙 요청 안 함), 'done', 'local_pending'(중앙 삭제됨, 로컬 적용은 다음 업로드 때),
  /// 'unconfirmed'(응답 불명 — 표시 유지·업로드 차단, 다시 요청 필요. 삭제는 여러 번 요청해도 안전 — Sol 3차 H-03d).
  /// 중앙이 확실히 거절(4xx)하면 이 표시만 지우고 예외를 올린다.
  static Future<String> requestDeletion(Future<void> Function() central,
      {bool Function(Object error)? isDefinitiveRefusal}) async {
    final begin = beginDeletion;
    String id;
    try {
      if (begin == null) return 'not_started';
      id = await begin();
    } catch (_) {
      return 'not_started';
    }
    try {
      await central();
    } catch (e) {
      if ((isDefinitiveRefusal ?? _definitiveRefusal)(e)) {
        try {
          await cancelDeletion?.call(id);
        } catch (_) {} // 지우지 못하면 업로드가 막힌 채 남는다(fail-closed)
        rethrow;
      }
      return 'unconfirmed';
    }
    try {
      final confirm = confirmDeletion;
      if (confirm == null) return 'local_pending';
      await confirm();
      return 'done';
    } catch (_) {
      return 'local_pending';
    }
  }

  /// 중앙이 처리하지 않았음이 확실한 거절: HTTP 4xx. 네트워크·타임아웃·5xx·그 밖 예외는 '불명'.
  static bool _definitiveRefusal(Object e) {
    if (e is! CommunityAccountError) return false;
    final status = e.httpStatus;
    return status != null && status >= 400 && status < 500;
  }

  static Future<bool> refreshServerCompletedNow() async {
    final fn = refreshServerCompleted;
    if (fn == null) return true;
    try {
      return await fn();
    } catch (_) {
      return false;
    }
  }

  static Future<void> registerBackgroundJobsNow() async {
    final fn = registerBackgroundJobs;
    if (fn == null) return;
    try {
      await fn();
    } catch (_) {}
  }

  static Future<void> catchUpNow(String reason) async {
    final fn = catchUp;
    if (fn == null) return;
    try {
      await fn(reason);
    } catch (_) {}
  }

  /// 로컬 차단까지 끝나면 true. 실패하면 false — 영속 표시가 남아 업로드·reshare 는 계속 막힌다(H-03).
  static Future<bool> contributionsDeletedNow() async {
    final fn = onContributionsDeleted;
    if (fn == null) return false;
    try {
      await fn();
      return true;
    } catch (_) {
      return false;
    }
  }
}
