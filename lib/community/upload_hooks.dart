import 'dart:async';

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

  /// 공유 자료 삭제 요청 순서(PC 라우트와 같음): 로컬 표시 → 중앙 삭제 → 로컬 적용.
  /// 반환: 'not_started'(표시를 못 써 중앙 요청 안 함), 'done', 'local_pending'(중앙 삭제됨, 로컬 적용은 다음 업로드 때).
  /// 중앙 호출이 실패하면 이 삭제의 표시만 지우고 예외를 그대로 올린다.
  static Future<String> requestDeletion(Future<void> Function() central) async {
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
    } catch (_) {
      try {
        await cancelDeletion?.call(id);
      } catch (_) {} // 지우지 못하면 업로드가 막힌 채 남는다(fail-closed)
      rethrow;
    }
    return await contributionsDeletedNow() ? 'done' : 'local_pending';
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
