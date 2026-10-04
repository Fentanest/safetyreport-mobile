# 변경 대상 경로 해석표

plan/findings의 파일명 약칭은 아래 현재 tracked 경로를 가리킨다. 함수·줄 위치는 findings 카드에 있고, 읽은 구간 상한은 review-scope.csv에 있다. 이 목록은 변경 허가나 전체 파일 검토를 뜻하지 않는다.

| 파일명·약칭 | 실제 경로 |
|---|---|
| `ClientGateGuard.kt` | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ClientGateGuard.kt` |
| `MainActivity.kt` | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/MainActivity.kt` |
| `NotificationService.kt` | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/NotificationService.kt` |
| `PrefsInbox.kt` | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/PrefsInbox.kt` |
| `ServerContract.kt` | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerContract.kt` |
| `ServerVersionCompatibility.kt` | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/ServerVersionCompatibility.kt` |
| `SyncForegroundService.kt` | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/SyncForegroundService.kt` |
| `WsService.kt` | `android/app/src/main/kotlin/com/fentanest/mysafetyreport/WsService.kt` |
| `capture_retry_store.dart` | `lib/community/capture/capture_retry_store.dart` |
| `rebuild_helpers.dart` | `lib/community/capture/rebuild_helpers.dart` |
| `server_completed.dart` | `lib/community/capture/server_completed.dart` |
| `community_store.dart` | `lib/community/community_store.dart` |
| `community_wiring.dart` | `lib/community/community_wiring.dart` |
| `community_gate.dart` | `lib/community/gate/community_gate.dart` |
| `community_rebuild.dart` | `lib/community/rebuild/community_rebuild.dart` |
| `community_uploader.dart` | `lib/community/upload/community_uploader.dart` |
| `main.dart` | `lib/main.dart` |
| `report_provider.dart / Provider` | `lib/providers/report_provider.dart` |
| `recent_answers_screen.dart` | `lib/screens/recent_answers_screen.dart` |
| `statistics_screen.dart` | `lib/screens/statistics_screen.dart` |
| `agency_registry.dart` | `lib/services/agency_registry.dart` |
| `api_service.dart` | `lib/services/api_service.dart` |
| `bounded_duplicate_rebuild.dart` | `lib/services/bounded_duplicate_rebuild.dart` |
| `client_media_access.dart` | `lib/services/client_media_access.dart` |
| `geocode_utils.dart` | `lib/services/geocode_utils.dart` |
| `local_db_service.dart / LocalDb` | `lib/services/local_db_service.dart` |
| `performance_trace.dart` | `lib/services/performance_trace.dart` |
| `prefs_inbox.dart` | `lib/services/prefs_inbox.dart` |
| `duplicate_repository.dart` | `lib/services/repositories/duplicate_repository.dart` |
| `server_contract.dart` | `lib/services/server_contract.dart` |
| `standalone_api_service.dart` | `lib/services/standalone_api_service.dart` |
| `standalone_auth_service.dart` | `lib/services/standalone_auth_service.dart` |
| `standalone_auto_sync_service.dart / auto_sync` | `lib/services/standalone_auto_sync_service.dart` |
| `standalone_pending_queue_store.dart` | `lib/services/standalone_pending_queue_store.dart` |
| `sync_engine.dart` | `lib/services/sync_engine.dart` |
| `local_paged_report_list.dart` | `lib/widgets/local_paged_report_list.dart` |
| `report_detail_sheet.dart` | `lib/widgets/report_detail_sheet.dart` |

공용파일은 PR별 다른 담당자가 동시에 변경하지 않는다. LocalDb/교환·read, Provider/main/UI, community store/gate/upload, native MainActivity·Manifest/Gradle, 정본 contract는 각 한 담당자가 순서대로 소유한다. 소유자 실명은 구현 승인 후 정하며 이번 검토에는 위임 작업이 없다.

PR6A 제안 신규 경로는 `lib/repositories/local_report_reads.dart`, `lib/services/local_statistics.dart`, `lib/services/local_database_exchange.dart`, `lib/services/sync_run_coordinator.dart`다. 기존 public facade가 호출을 위임하도록 먼저 기계적으로 이동하고, 반환·오류·초기화·dispose 순서가 같은지 확인한다. 이 경로들은 아직 존재하지 않으며 이번에는 생성하지 않았다.
