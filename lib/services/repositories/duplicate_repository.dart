import '../../models/app_mode.dart';
import '../../models/duplicate_group.dart';
import '../../providers/report_provider.dart';
import '../api_service.dart';
import '../duplicate_projection_service.dart';
import '../local_db_service.dart';

/// 중복 신고 그룹 fetch / 갱신 인터페이스.
/// `DuplicateManagementPanel` 이 mode 분기를 직접 하지 않게 한다.
abstract class DuplicateRepository {
  Future<List<DuplicateGroup>> getGroups();

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
  Future<List<DuplicateGroup>> getGroups() async {
    final db = await LocalDbService.db;
    await DuplicateProjectionService.createSchema(db);
    await DuplicateProjectionService.refreshDuplicateGroups(db);
    return DuplicateProjectionService.getDuplicateGroups(db);
  }

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
  Future<List<DuplicateGroup>> getGroups() => _api.getDuplicateGroups();

  @override
  Future<void> updateGroup(
    String groupId, {
    required String duplicateStatus,
    required String representativeMode,
    required String representativeId,
    required String note,
  }) =>
      _api.updateDuplicateGroup(
        groupId,
        duplicateStatus: duplicateStatus,
        representativeMode: representativeMode,
        representativeId: representativeId,
        note: note,
      );
}
