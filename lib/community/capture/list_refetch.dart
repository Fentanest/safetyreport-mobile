// 증분 선정 규칙 (contracts vectors/list_refetch.json, 규칙 문장 그대로).
//
// 비교 기준은 community.db 의 detail_status 라벨(개인 DB 상태 열 아님).
// null 을 `!=` 로 직접 비교하지 않는다. closed/supplement_open 은 사이트 값
// (override 무시 — 호출자가 사이트 원본을 넘긴다, A07).
bool shouldRefetchListItem({
  required bool inPersonalDetail,
  required String? listLabel,
  required String? detailStatusLabel,
  required String? closed,
  required String? supplementOpen,
  required bool rebuildFailedPermanent,
  required String? failedListLabel,
  required bool inCaptureRetry,
}) {
  if (!inPersonalDetail) return true;
  if ((closed ?? '') != 'Y') return true;
  if (supplementOpen == 'Y') return true;
  if (inCaptureRetry) return true;
  if (detailStatusLabel == null) {
    if (!rebuildFailedPermanent) return true;
    if (failedListLabel == null) return true;
    return listLabel != failedListLabel;
  }
  if (listLabel == null) return true;
  return listLabel != detailStatusLabel;
}
