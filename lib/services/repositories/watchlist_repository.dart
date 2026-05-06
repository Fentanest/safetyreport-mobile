import '../../models/app_mode.dart';
import '../../models/report.dart';
import '../../providers/report_provider.dart';
import '../api_service.dart';
import '../local_db_service.dart';

/// Client/Standalone 양쪽 모두에서 동일한 인터페이스로 감시 목록을 읽는다.
/// `WatchlistPanel` 같은 재사용 패널이 모드 분기를 직접 하지 않게 하는 게 목적.
abstract class WatchlistRepository {
  Future<List<Report>> getReports();

  factory WatchlistRepository.fromProvider(ReportProvider provider) {
    if (provider.appMode == AppMode.standalone) {
      return _StandaloneWatchlistRepository(
        excludeWithdraw: provider.excludeWithdraw,
        normalizePolice: provider.normalizePolice,
        useRepresentativeRecords: provider.useRepresentativeRecords,
      );
    }
    return _ServerWatchlistRepository(
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
    );
  }
}

class _StandaloneWatchlistRepository implements WatchlistRepository {
  final bool excludeWithdraw;
  final bool normalizePolice;
  final bool useRepresentativeRecords;

  _StandaloneWatchlistRepository({
    required this.excludeWithdraw,
    required this.normalizePolice,
    required this.useRepresentativeRecords,
  });

  @override
  Future<List<Report>> getReports() => LocalDbService.getWatchlistReports(
        excludeWithdraw: excludeWithdraw,
        normalizePolice: normalizePolice,
        useRepresentativeRecords: useRepresentativeRecords,
      );
}

class _ServerWatchlistRepository implements WatchlistRepository {
  final String baseUrl;
  final String apiKey;

  _ServerWatchlistRepository({required this.baseUrl, required this.apiKey});

  @override
  Future<List<Report>> getReports() =>
      ApiService(baseUrl: baseUrl, apiKey: apiKey).getWatchlist();
}
