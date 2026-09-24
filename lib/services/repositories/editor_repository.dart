import '../../models/app_mode.dart';
import '../../models/editor_schema.dart';
import '../../providers/report_provider.dart';
import '../api_service.dart';
import '../local_db_service.dart';

abstract class EditorRepository {
  Future<EditorSchema> getSchema();

  Future<Map<String, dynamic>?> getRecord(String category, String recordId);

  Future<bool> saveRecord(
    String category,
    String recordId,
    Map<String, dynamic> values,
  );

  /// 사용자가 고친 필드와 그 필드의 안전신문고 원본 값(저장 계층 재설계 R4). 고친 필드가 없으면 빈 맵.
  Future<Map<String, String?>> getSiteValuesOfEditedFields(
    String category,
    String recordId,
  );

  factory EditorRepository.fromProvider(ReportProvider provider) {
    if (provider.appMode == AppMode.standalone) {
      return _StandaloneEditorRepository();
    }
    return _ServerEditorRepository(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
    );
  }
}

class _StandaloneEditorRepository implements EditorRepository {
  @override
  Future<EditorSchema> getSchema() async => EditorSchema.fallback();

  @override
  Future<Map<String, dynamic>?> getRecord(String category, String recordId) {
    return LocalDbService.getEditableRecord(recordId);
  }

  @override
  Future<bool> saveRecord(
    String category,
    String recordId,
    Map<String, dynamic> values,
  ) {
    return LocalDbService.updateEditableRecord(recordId, values);
  }

  @override
  Future<Map<String, String?>> getSiteValuesOfEditedFields(
    String category,
    String recordId,
  ) {
    return LocalDbService.getSiteValuesOfEditedFields(recordId);
  }
}

class _ServerEditorRepository implements EditorRepository {
  final String baseUrl;
  final String apiKey;
  Map<String, String?> _lastSiteValues = const {};

  /// 서버는 레코드 응답에 site_values 를 함께 준다(구서버는 없음 → 빈 맵). getRecord 뒤에 부른다.
  @override
  Future<Map<String, String?>> getSiteValuesOfEditedFields(
    String category,
    String recordId,
  ) async => _lastSiteValues;

  _ServerEditorRepository({required this.baseUrl, required this.apiKey});

  ApiService get _api => ApiService(baseUrl: baseUrl, apiKey: apiKey);

  @override
  Future<EditorSchema> getSchema() async {
    final schema = await _api.getEditorSchema();
    return EditorSchema.fromJson(schema);
  }

  @override
  Future<Map<String, dynamic>?> getRecord(
    String category,
    String recordId,
  ) async {
    final payload = await _api.getEditableRecord(category, recordId);
    _lastSiteValues = {
      for (final e in ((payload['site_values'] as Map?) ?? const {}).entries)
        e.key.toString(): e.value?.toString(),
    };
    final nestedRecord = payload['record'];
    if (nestedRecord is Map) {
      return Map<String, dynamic>.from(nestedRecord);
    }
    return payload;
  }

  @override
  Future<bool> saveRecord(
    String category,
    String recordId,
    Map<String, dynamic> values,
  ) async {
    await _api.saveEditableRecord(category, recordId, values);
    return true;
  }
}
