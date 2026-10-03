import 'package:sqflite/sqflite.dart';
import '../../models/app_mode.dart';
import '../../models/duplicate_group.dart';
import '../../providers/report_provider.dart';
import '../api_service.dart';
import '../duplicate_projection_service.dart';
import '../local_db_service.dart';

/// 중복 신고 그룹 fetch / 갱신 인터페이스.
/// `DuplicateManagementPanel` 이 mode 분기를 직접 하지 않게 한다.
abstract class DuplicateRepository {
  Future<List<DuplicateGroup>> getGroups({String? status, int page = 0});
  Future<Map<String, int>> getStatusCounts();
  Future<List<DuplicateMember>> getMembers(String groupId, {int page = 0});

  Future<void> updateGroup(
    String groupId, {
    required String duplicateStatus,
    required String representativeMode,
    required String representativeId,
    required String note,
  });

  factory DuplicateRepository.fromProvider(ReportProvider provider) {
    if (provider.appMode == AppMode.standalone) {
      return _StandaloneDuplicateRepository();
    }
    return _ServerDuplicateRepository(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
    );
  }
}

class _StandaloneDuplicateRepository implements DuplicateRepository {
  @override
  Future<List<DuplicateGroup>> getGroups({String? status, int page = 0}) async {
    final db = await LocalDbService.db;
    // 화면을 열 때마다 전체 재생성하지 않는다(M-18). 그룹은 동기화·가져오기·복원 뒤에 다시 계산된다.
    // 아직 한 번도 계산하지 않은 DB(그룹 표가 비었을 때)만 여기서 계산한다.
    final existing =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM ${DuplicateProjectionService.groupTable}',
          ),
        ) ??
        0;
    if (existing == 0 &&
        !await DuplicateProjectionService.hasCompletedProjection(db)) {
      await DuplicateProjectionService.refreshDuplicateGroups(db);
    }
    return DuplicateProjectionService.getDuplicateGroups(
      db,
      status: status,
      page: page,
    );
  }

  @override
  Future<Map<String, int>> getStatusCounts() async => {
    for (final r in await (await LocalDbService.db).rawQuery(
      'SELECT status,COUNT(*) AS n FROM duplicate_group GROUP BY status',
    ))
      r['status'] as String: r['n'] as int,
  };
  @override
  Future<List<DuplicateMember>> getMembers(
    String groupId, {
    int page = 0,
  }) async => DuplicateProjectionService.getDuplicateMembers(
    await LocalDbService.db,
    groupId,
    page: page,
  );

  @override
  Future<void> updateGroup(
    String groupId, {
    required String duplicateStatus,
    required String representativeMode,
    required String representativeId,
    required String note,
  }) async {
    final db = await LocalDbService.db;
    await DuplicateProjectionService.updateDuplicateGroup(
      db,
      groupId,
      duplicateStatus: duplicateStatus,
      representativeMode: representativeMode,
      representativeId: representativeId,
      note: note,
    );
    await DuplicateProjectionService.refreshDuplicateGroups(db);
  }
}

class _ServerDuplicateRepository implements DuplicateRepository {
  final String baseUrl;
  final String apiKey;

  _ServerDuplicateRepository({required this.baseUrl, required this.apiKey});

  ApiService get _api => ApiService(baseUrl: baseUrl, apiKey: apiKey);

  @override
  Future<List<DuplicateGroup>> getGroups({String? status, int page = 0}) =>
      _api.getDuplicateGroups(status: status);
  @override
  Future<Map<String, int>> getStatusCounts() async {
    final groups = await _api.getDuplicateGroups();
    final counts = <String, int>{};
    for (final group in groups) {
      counts.update(group.status, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  @override
  Future<List<DuplicateMember>> getMembers(
    String groupId, {
    int page = 0,
  }) async => (await _api.getDuplicateGroups())
      .firstWhere((g) => g.groupId == groupId)
      .members;

  @override
  Future<void> updateGroup(
    String groupId, {
    required String duplicateStatus,
    required String representativeMode,
    required String representativeId,
    required String note,
  }) => _api.updateDuplicateGroup(
    groupId,
    duplicateStatus: duplicateStatus,
    representativeMode: representativeMode,
    representativeId: representativeId,
    note: note,
  );
}
