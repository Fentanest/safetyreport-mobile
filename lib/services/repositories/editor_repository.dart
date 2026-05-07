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
}

class _ServerEditorRepository implements EditorRepository {
  final String baseUrl;
  final String apiKey;

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
