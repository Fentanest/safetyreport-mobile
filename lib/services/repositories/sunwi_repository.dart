import 'dart:async';

import '../../models/app_mode.dart';
import '../../models/sunwi.dart';
import '../../providers/report_provider.dart';
import '../api_service.dart';
import '../sunwi_service.dart';

/// 한 번의 신고현황 fetch 결과. payload 는 항상 존재, dataset 은 standalone 만.
class SunwiSnapshot {
  final SunwiPayload payload;
  final SunwiDataset? dataset;
  const SunwiSnapshot({required this.payload, this.dataset});
}

/// 신고현황 데이터 source 단일 인터페이스. `SunwiSection` 이 mode 분기를
/// 직접 하지 않도록 모음.
abstract class SunwiRepository {
  /// payload (+ 가능하면 dataset) fetch. progress 는 standalone 에서만 동작.
  Future<SunwiSnapshot> fetch({
    void Function(int completed, int total, String label)? onProgress,
  });

  factory SunwiRepository.fromProvider(ReportProvider provider) {
    if (provider.appMode == AppMode.standalone) {
      return _StandaloneSunwiRepository();
    }
    return _ServerSunwiRepository(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
    );
  }
}

class _StandaloneSunwiRepository implements SunwiRepository {
  @override
  Future<SunwiSnapshot> fetch({
    void Function(int, int, String)? onProgress,
  }) async {
    final dataset = await SunwiService.fetchStandalone(onProgress: onProgress);
    unawaited(_writeLatestCsvs(dataset));
    return SunwiSnapshot(payload: dataset.payload, dataset: dataset);
  }

  Future<void> _writeLatestCsvs(SunwiDataset dataset) async {
    try {
      await SunwiService.exportStandaloneCsv(dataset, top5: false);
      await SunwiService.exportStandaloneCsv(dataset, top5: true);
    } catch (_) {}
  }
}

class _ServerSunwiRepository implements SunwiRepository {
  final String baseUrl;
  final String apiKey;

  _ServerSunwiRepository({required this.baseUrl, required this.apiKey});

  ApiService get _api => ApiService(baseUrl: baseUrl, apiKey: apiKey);

  @override
  Future<SunwiSnapshot> fetch({
    void Function(int, int, String)? onProgress,
  }) async {
    final payload = await _api.getSunwiPayload();
    return SunwiSnapshot(payload: payload);
  }
}
