# Sol에게 전달할 모바일 전체 리팩터링 계획 검토 프롬프트

아래 구분선 안의 내용을 현재 `safetyreport-mobile` 작업 세션에 전달한다. 문서 경로는 이 패키지를 실제 놓은 위치에서 확인한다. 루트에 존재하지 않는 파일을 이미 배치됐다고 가정하지 않는다.

---

현재 열린 `Fentanest/safetyreport-mobile`의 `dev`를 대상으로 전체 리팩터링 **계획만** 검토·상세화해.

**!계획만!** 코드를 수정하거나 구현·테스트·벤치마크·앱 실행·빌드·기기 조작·외부 API 호출을 시작하지 마. 계획을 제출한 뒤 자동으로 구현에 넘어가지 마. 지금 허용된 작업은 읽기 전용 소스 확인과 계획 문서 작성이다.

## 1. 입력을 먼저 끝까지 읽어

전달한 폴더의 다음 문서를 순서대로 읽어.

1. `01_safetyreport_mobile_dev_refactoring_plan_ko.md`
2. `04_work_items_and_evidence_ko.md`
3. `03_source_audit_original.md`
4. `05_traceability_index.json`, `06_benchmark_record_template.json`

앞부분만 읽고 부록을 추측하지 마. 원문 감사의 발견 ID·한계·이미 반영된 개선을 유지해. 문서가 있다고 해당 테스트를 실행한 것으로 취급하지 마.

현재 `AGENTS.md`, `PROJECT_RULES.md`와 관련 architecture/design/contract/skill을 실제 경로에서 확인해. 참조 파일이 없으면 없음으로 기록하고 대체 경로를 근거로 찾아. 없는 API·파일·도구·모델을 지어내지 마. 원본 감사와 입력 계획은 바꾸지 말고 별도 결과 문서에 반증·수정 사항을 적어.

## 2. 현재 작업 상태와 근거를 고정해

검토 기준 SHA는 `ea183b2a94b62ec9bd51b0f2ab8bd9e72f075b60`이다. 이 SHA로 reset/checkout하라는 뜻이 아니다. 현재 branch·HEAD·작업 트리·원격 dev와의 차이·사용자 기존 변경을 읽기 전용으로 확인하고 보존해.

HEAD가 달라졌으면 기준 이후의 diff를 먼저 확인해. 같더라도 감사의 추론이 정답이라고 맹신하지 마. 각 발견을 `현재 확인 / 이미 해결 / 반증 / 미재현 / 판단 근거 부족`으로 분류하고 파일·함수·현재 줄 위치·발생 조건·보호 장치를 적어.

첨부 감사가 조사한 624개 파일과 이번에 네가 실제 읽은 범위를 분리해. 전체 목록 확인, 텍스트 확보, 구조 스캔, 핵심 경로 검토, 실제 실행을 서로 다른 증거로 기록해. 기존 868 passed/15 skipped·Kotlin 4건·50만 건 성능/교환 기록을 이번 결과로 복사하지 마.

## 3. 목표와 절대 보존할 것

이 앱은 이미 접수한 신고 조회·관리 앱이다. Client(`AppMode.server`)의 서버 크롤링과 Standalone의 로컬 동기화는 다르다.

기존 Flutter/Provider/Navigator/sqflite 구조, 하단 5탭·각 하위 분류·옛 native 5/6·quick_sync/quick_crawl·상세 이동·선택 취소·출처/비공식 고지·라이트/다크·IME·큰 글자를 유지해.

DB 교환은 성능보다 우선한다. 서버↔모바일의 모든 교환 entity·컬럼 값과 타입, NULL/빈값·ID 선행 0·한글/개행·날짜·raw·override·중복 결정/member·sync_meta·owner를 보존해. 현재 schema 5/16, 제품 VERSION, protocol 3을 섞지 마. 컬럼·값 의미·변환 변경은 양쪽 정본·변환·왕복·배포 순서를 같은 작업 단위로 계획하되, 다른 저장소 구현은 시작하지 마.

통계의 raw/canonical 상태·lifecycle·중복 projection과 중첩 처분을 구분해. 확정 금액과 추정 금액을 합치지 마. 수동 대표·동률·not_duplicate/review_required·비대표 감시의 계승·기관 identity·결측/분모/날짜 규칙을 유지해.

기능 삭제·샘플링·상위 N건만 집계·큰 데이터 숨기기·largeHeap·권한 완화·프레임워크 교체·최소 Android 상향을 기본 해법으로 삼지 마. map의 랭킹 3탭을 모바일 통계에 가져오지 마. 신규 인사이트·운영 포인트·중복 KPI 카드도 추가하지 마.

## 4. 이미 반영된 개선을 다시 미구현으로 쓰지 마

현재는 SQL COUNT/조건 집계, preview 200, 통계의 narrow TEMP GROUP BY와 1,000그룹 전달, revision/epoch/sequence, native 큐 진입 전 취소 검사, viewport 지도, lazy 탭/ListView, 128행 digest와 staging 기반 중복 재생성, 50그룹/멤버 페이지, 128행 JOIN 가져오기, 사진 decode 크기와 MediaStore 개선 등이 있다.

새 계획은 이 보호 위에서 **cold 준비·집계·복사·반복 작업**을 줄이는 계획이어야 한다. 모든 Report를 먼저 로드하고 isolate에서 처리하는 방식으로 돌아가지 마.

## 5. 27개 발견을 빠짐없이 처리해

다음 ID를 유지해: `DB-01~DB-06`, `UI-01~UI-04`, `N-01~N-09`, `S-01~S-08`.

우선 S-02의 불완전 HTTP 200 목록에 의한 부재 행 삭제를 확인해. total 일치만으로 안정된 전체 목록이라고 판단하지 마. DB-01/02의 WAL·snapshot 실패, JOIN/orphan/ID/cursor/REPLACE에 의한 부분 가져오기에서는 실패 시 기존 정상 DB를 보존하는 설계를 먼저 세워.

S-01은 pending/retryable이 남아도 rebuild를 완료하는지 확인하고 영속 item 상태와 commit 직전 원자 검증으로 설계해. N-04/S-03/S-04는 history 200개와 processing queue를 분리하고, failed/busy/일시 HTTP 오류의 ACK 및 같은 번호의 새 event 유실을 막아.

N-02/03/S-05/06은 Dart/native/업로드의 owner·generation·freshness·실제 취소 경계를 일치시켜. 나머지 항목도 최소 반례·현재 방어·반증법·변경 경계·선행 테스트·명시 acceptance·rollback을 적어. 실제 운영 피해·S24 OOM·침해 발생으로 단정하지 마.

## 6. 성능 계획을 구체화해

첫 프레임, DB open/인덱스, registry, 첫 유용한 데이터, 전체 결과 완료를 구분해. SQL native 실행·큐 대기·MethodChannel·JSON/Report·누산·Provider·UI/raster·파일·HTTP를 분리해.

통계 high-cardinality CTAS/그룹 압축률·반복 parse/누산, giant 중복 hash/staging/publish, build별 정렬, 동일 cold query 중복, Client의 limit1+page 비용, 누적 captured ID 진행 조회, drain의 건별 중복 재계산, manifest 전체 갱신을 실제 함수와 연결해.

0/1/3k/58,388/100k/500k, 긴 원문·NULL·같은 건수 수정·giant 1~2군·고카디널리티·느린 네트워크·동시 writer를 분리해. 기기/RAM/build/seed가 다른 기록을 전후 개선율로 합치지 마.

warm 1ms로 cold 문제가 해결됐다고 하지 마. timeout/실패 표본을 빼지 마. 세 번 실행으로 안정적 p95라고 하지 마. 측정하지 않은 수치는 null/미측정으로 남겨. 배터리 절감은 실제 측정이 없으면 후보로만 보고해.

## 7. 특히 잘못 이해하지 말 것

`Future.timeout`은 transport/DB 작업 취소가 아니다. native SQL의 실제 중단 지원보다 강한 보장을 만들지 마. atomic save 도중 취소와 UI 이탈은 구분해.

FGS 알림이 있다고 Dart engine과 작업이 살아 있는 것은 아니다. HOME, Activity 재생성, task removal, process death, force-stop은 별도다. 기본은 owner 확인과 checkpoint 복구이며 headless 전면 재설계는 별도 결정이야.

gate의 60초/600초 정책은 열람과 신규 작업, foreground/background로 나눠 검증해. 600초 자체를 무조건 버그라고 하지 마. `personal_save_state`는 현재 표시용 계약이므로 임의의 sendability 필터를 추가하지 마.

원격 POST 응답 유실은 미접수 증거가 아니다. 별점·큐 등록·업로드는 멱등·ACK 계약에 맞게 재시도하고, 알 수 없으면 unknown outcome을 남겨. 새 서버 필드를 가정하지 마.

## 8. Client와 다른 저장소 의존성을 분리해

`docs/architecture/client-read-handoff.md`의 현재 구현과 제안은 다르다. 실제 category page/viewport map은 유지해. 후보 page 200개에서의 조건 일치 수를 전체 필터 total로 표시하지 마.

watchlist/recent totals, scoped count/page, group/member/missing page, 전체 filter 메타와 ID lookup은 정본 확정 여부부터 확인해. 미확정 API를 호출하는 구현 계획은 쓰지 마.

모바일 내부 취소·상태·decode·메모리 개선과 서버 계약 완료 후 가능한 전체 filtered 조회는 별도 단위로 나눠. PC 거대 중복군 복원 미완료와 일반 500k 왕복 성공도 분리해. 서버 공동 검증이 없으면 해당 게이트만 BLOCKED로 남기되 모바일 독립 계획을 비우지 마.

## 9. 단계·검수·롤백

기존 계획의 PR0~PR6와 하위 변경 단위를 출발점으로 의존성을 검증해. 단일 거대 rewrite를 제안하지 마. main/Provider/LocalDb/community 공통/contract/Manifest/Gradle은 한 담당자 소유로 계획해.

각 단위마다 대상 파일·함수, 현재 흐름과 변경 흐름, 새 파일은 ‘제안 신규’ 표시, 대안과 기각 이유, 공용 facade·DB/API 영향, 선행 테스트, 합격 기준, 롤백, 잔여 제약을 적어.

정확성·안전성 PR과 성능 PR과 기계적 파일 이동을 섞지 마. 과거 모델 역할·기기 접근 문서가 이번 실행 승인은 아니다. 도구가 없는데 독립 검수했다고 쓰지 마.

테스트 실행은 지금 하지 말고, 승인 후 격리 fixture에서 실행할 명령·환경·검증 범위만 설계해. 운영 앱 uninstall/pm clear, 실계정·키·서명·VERSION 변경, 실제 크롤·별점·공유 업로드는 금지다.

## 10. 최종 계획 산출물

한국어로 다음을 완성해.

1. 현재 HEAD/delta·실제 검토 범위·확인된 사실/가설/과거 측정/제안 구분.
2. 가장 중요한 안전성 위험과 성능 병목, 이미 해결된 점.
3. 기능/데이터/writer/owner/lock·lease/cancel 지도.
4. 27개 발견의 재분류와 각각의 회귀 fixture·acceptance·rollback.
5. PR 단위 구체 계획·의존성·모바일 단독/서버 공동 구분.
6. 모든 컬럼 DB 왕복·API/WS/protocol·실렌더·접근성·native 수명 검증 계획.
7. 동일 조건 baseline/after 기록 양식과 실행 전제. 실제 값이 없으면 미측정.
8. 미결정 정책의 합리적인 기본안, 영향받는 작업만 보류하는 조건.
9. 첫 구현 승인 대상과 그 통과 조건.

추상적인 ‘캐시 추가/쿼리 최적화/비동기화’ 목록만 내지 마. 이미 문서에 정해진 것을 다시 질문하며 멈추지 말고 근거 있는 권장안을 작성해. 반증된 발견은 제거해도 되지만 왜 제거했는지 증거를 남겨.

**계획을 제출한 뒤 종료해. 구현·테스트·벤치마크·앱 실행·배포로 자동 전환하지 마.**

---
