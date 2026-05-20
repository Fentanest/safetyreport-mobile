import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/report_map.dart';
import 'app_prefs_keys.dart';
import 'geocode_utils.dart';
import 'local_db_service.dart';
import 'standalone_auto_sync_service.dart';
import 'sync_engine.dart';

const _kakaoAddressUrl = 'https://dapi.kakao.com/v2/local/search/address.json';

class GeocodeConfigurationError implements Exception {
  final String message;

  GeocodeConfigurationError(this.message);

  @override
  String toString() => message;
}

class GeocodeProviderError implements Exception {
  final String message;

  GeocodeProviderError(this.message);

  @override
  String toString() => message;
}

class LocalGeocodeService {
  static Future<void>? _runningTask;
  static Map<String, dynamic> _progressState = _initialProgressState();
  static const _remainingCountEveryRows = 40;
  static const _queuedMessage = '동기화 또는 DB 가져오기가 끝나면 주소 좌표 변환을 자동으로 다시 시작합니다.';

  static Map<String, dynamic> _initialProgressState() {
    return {
      'state': 'idle',
      'running': false,
      'total': 0,
      'processed': 0,
      'updated': 0,
      'not_found': 0,
      'remaining_missing': 0,
      'progress_pct': 0.0,
      'error_message': '',
      'started_at': 0,
      'finished_at': 0,
      'has_saved_coordinates': false,
    };
  }

  static GeocodeBackfillProgress currentProgress() =>
      GeocodeBackfillProgress.fromJson(_progressState);

  static bool _shouldQueueForSync() =>
      SyncEngine.isRunning || StandaloneAutoSyncService.isRunning;

  static Future<GeocodeBackfillProgress> ensureMapBackfillStartedFromStoredKey({
    int batchSize = 80,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    return ensureMapBackfillStarted(
      apiKey: prefs.getString(AppPrefsKeys.standaloneKakaoRestApiKey) ?? '',
      batchSize: batchSize,
    );
  }

  static GeocodeBackfillProgress _setProgressState(
    Map<String, dynamic> updates,
  ) {
    _progressState = {..._progressState, ...updates};
    final total = (_progressState['total'] as num?)?.toInt() ?? 0;
    final processed = (_progressState['processed'] as num?)?.toInt() ?? 0;
    if (total > 0) {
      _progressState['progress_pct'] =
          ((processed > total ? total : processed) / total * 100)
              .toStringAsFixed(1);
      _progressState['progress_pct'] =
          double.tryParse(_progressState['progress_pct'].toString()) ?? 0;
    } else if (_progressState['state'] == 'completed') {
      _progressState['progress_pct'] = 100.0;
    } else {
      _progressState['progress_pct'] = 0.0;
    }
    return currentProgress();
  }

  static GeocodeBackfillProgress _queueBackfill({
    required int total,
    required int processed,
    required int updated,
    required int notFound,
    required int remainingMissing,
    required bool hasSavedCoordinates,
    int? startedAt,
  }) {
    return _setProgressState({
      'state': 'queued',
      'running': false,
      'total': total,
      'processed': processed,
      'updated': updated,
      'not_found': notFound,
      'remaining_missing': remainingMissing,
      'error_message': _queuedMessage,
      'finished_at': DateTime.now().millisecondsSinceEpoch,
      'has_saved_coordinates': hasSavedCoordinates,
      if (startedAt != null) 'started_at': startedAt,
    });
  }

  static Future<int> countSavedCoordinateRecords() async {
    final d = await LocalDbService.db;
    final rows = await d.rawQuery('''
      SELECT COUNT(*) AS cnt
      FROM geocode_cache
      WHERE 상태 = 'ok'
    ''');
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['cnt']?.toString() ?? '') ?? 0;
  }

  static Future<int> countCacheBackfillableReports() async {
    final d = await LocalDbService.db;
    final rows = await d.rawQuery('''
      SELECT COUNT(*) AS cnt
      FROM reports r
      INNER JOIN geocode_cache c
        ON c.주소정규화 = TRIM(COALESCE(NULLIF(r.주소정규화, ''), r.위반장소))
      WHERE r.위반장소 IS NOT NULL
        AND TRIM(r.위반장소) != ''
        AND (r.위도 IS NULL OR r.경도 IS NULL)
        AND COALESCE(r.지오코딩상태, '') != 'not_found'
        AND c.상태 IN ('ok', 'not_found')
    ''');
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['cnt']?.toString() ?? '') ?? 0;
  }

  static Future<({String state, String message, bool hasSavedCoordinates})>
  _missingApiKeyNotice() async {
    final hasSavedCoordinates = (await countSavedCoordinateRecords()) > 0;
    if (hasSavedCoordinates) {
      return (
        state: 'config_warning',
        message:
            '저장된 좌표 데이터는 계속 지도에 반영됩니다. 다만 DB에 없는 새 주소는 카카오 REST API 키가 없으면 변환할 수 없습니다.',
        hasSavedCoordinates: true,
      );
    }
    return (
      state: 'config_required',
      message: '모바일 설정에서 카카오 REST API 키를 확인하세요.',
      hasSavedCoordinates: false,
    );
  }

  static Future<GeocodeBackfillProgress> ensureMapBackfillStarted({
    required String apiKey,
    int batchSize = 80,
  }) async {
    if (_runningTask != null) return currentProgress();

    final pending = await countPendingReports();
    final hasSavedCoordinates = (await countSavedCoordinateRecords()) > 0;
    if (pending <= 0) {
      return _setProgressState({
        'state': 'completed',
        'running': false,
        'total': 0,
        'processed': 0,
        'updated': 0,
        'not_found': 0,
        'remaining_missing': 0,
        'error_message': '',
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'has_saved_coordinates': hasSavedCoordinates,
      });
    }

    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty && (await countCacheBackfillableReports()) <= 0) {
      final notice = await _missingApiKeyNotice();
      return _setProgressState({
        'state': notice.state,
        'running': false,
        'total': pending,
        'processed': 0,
        'updated': 0,
        'not_found': 0,
        'remaining_missing': pending,
        'error_message': notice.message,
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'has_saved_coordinates': notice.hasSavedCoordinates,
      });
    }

    if (_shouldQueueForSync()) {
      return _queueBackfill(
        total: pending,
        processed: 0,
        updated: 0,
        notFound: 0,
        remainingMissing: pending,
        hasSavedCoordinates: hasSavedCoordinates,
        startedAt: 0,
      );
    }

    _setProgressState({
      'state': 'running',
      'running': true,
      'total': pending,
      'processed': 0,
      'updated': 0,
      'not_found': 0,
      'remaining_missing': pending,
      'error_message': '',
      'started_at': DateTime.now().millisecondsSinceEpoch,
      'finished_at': 0,
      'has_saved_coordinates': hasSavedCoordinates,
    });

    _runningTask = _runBackfill(apiKey: trimmedKey, batchSize: batchSize);
    unawaited(
      _runningTask!.whenComplete(() {
        _runningTask = null;
      }),
    );
    return currentProgress();
  }

  static Future<int> countPendingReports() async {
    final d = await LocalDbService.db;
    final rows = await d.rawQuery('''
      SELECT COUNT(*) AS cnt
      FROM reports
      WHERE 위반장소 IS NOT NULL
        AND TRIM(위반장소) != ''
        AND (위도 IS NULL OR 경도 IS NULL)
        AND COALESCE(지오코딩상태, '') != 'not_found'
    ''');
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['cnt']?.toString() ?? '') ?? 0;
  }

  static Future<void> _runBackfill({
    required String apiKey,
    required int batchSize,
  }) async {
    var processed = 0;
    var updated = 0;
    var notFound = 0;
    var remainingMissing = 0;
    var recountCountdown = 0;
    final cacheOnlyMode = apiKey.trim().isEmpty;
    var hasSavedCoordinates = (await countSavedCoordinateRecords()) > 0;

    try {
      remainingMissing = await countPendingReports();
      while (true) {
        if (_shouldQueueForSync()) {
          _queueBackfill(
            total:
                (_progressState['total'] as num?)?.toInt() ?? remainingMissing,
            processed: processed,
            updated: updated,
            notFound: notFound,
            remainingMissing: remainingMissing,
            hasSavedCoordinates: hasSavedCoordinates,
          );
          return;
        }

        final d = await LocalDbService.db;
        final rows = cacheOnlyMode
            ? await d.rawQuery(
                '''
                SELECT r.ID, r.위반장소, r.주소정규화, r.행정구역, r.위도, r.경도, r.지오코딩상태
                FROM reports r
                INNER JOIN geocode_cache c
                  ON c.주소정규화 = TRIM(COALESCE(NULLIF(r.주소정규화, ''), r.위반장소))
                WHERE r.위반장소 IS NOT NULL
                  AND TRIM(r.위반장소) != ''
                  AND (r.위도 IS NULL OR r.경도 IS NULL)
                  AND COALESCE(r.지오코딩상태, '') != 'not_found'
                  AND c.상태 IN ('ok', 'not_found')
                ORDER BY r.ID DESC
                LIMIT ?
                ''',
                [batchSize],
              )
            : await d.query(
                'reports',
                columns: ['ID', '위반장소', '주소정규화', '행정구역', '위도', '경도', '지오코딩상태'],
                where: '''
                  위반장소 IS NOT NULL
                  AND TRIM(위반장소) != ''
                  AND (위도 IS NULL OR 경도 IS NULL)
                  AND COALESCE(지오코딩상태, '') != 'not_found'
                ''',
                orderBy: 'ID DESC',
                limit: batchSize,
              );

        if (rows.isEmpty) break;

        for (final row in rows) {
          if (_shouldQueueForSync()) {
            _queueBackfill(
              total:
                  (_progressState['total'] as num?)?.toInt() ??
                  (processed + remainingMissing),
              processed: processed,
              updated: updated,
              notFound: notFound,
              remainingMissing: remainingMissing,
              hasSavedCoordinates: hasSavedCoordinates,
            );
            return;
          }

          final normalizedRow = Map<String, dynamic>.from(row);
          final reportId = normalizedRow['ID']?.toString() ?? '';
          final address = normalizedRow['위반장소']?.toString() ?? '';
          processed++;
          recountCountdown += 1;

          try {
            final payload = await resolveAddress(apiKey, address);
            final nextStatus = payload['지오코딩상태']?.toString() ?? '';
            await _applyGeoPayload(reportId, payload);
            if (nextStatus == 'ok') {
              updated++;
              remainingMissing = remainingMissing > 0
                  ? remainingMissing - 1
                  : 0;
            } else if (nextStatus == 'not_found') {
              notFound++;
              remainingMissing = remainingMissing > 0
                  ? remainingMissing - 1
                  : 0;
            }
          } on GeocodeConfigurationError catch (exc) {
            await _applyGeoPayload(
              reportId,
              buildPendingGeoPayload(address, status: 'error'),
            );
            final notice = await _missingApiKeyNotice();
            _setProgressState({
              'state': notice.state,
              'running': false,
              'processed': processed,
              'updated': updated,
              'not_found': notFound,
              'remaining_missing': remainingMissing,
              'error_message': notice.message.isNotEmpty
                  ? notice.message
                  : exc.message,
              'finished_at': DateTime.now().millisecondsSinceEpoch,
              'has_saved_coordinates': notice.hasSavedCoordinates,
            });
            return;
          } on GeocodeProviderError catch (exc) {
            await _applyGeoPayload(
              reportId,
              buildPendingGeoPayload(address, status: 'error'),
            );
            final adjustedRemaining = remainingMissing > 0
                ? remainingMissing
                : await countPendingReports();
            _setProgressState({
              'state': 'error',
              'running': false,
              'processed': processed,
              'updated': updated,
              'not_found': notFound,
              'remaining_missing': adjustedRemaining,
              'error_message': '카카오 주소 변환 실패: ${exc.message}',
              'finished_at': DateTime.now().millisecondsSinceEpoch,
              'has_saved_coordinates': hasSavedCoordinates,
            });
            return;
          }

          hasSavedCoordinates =
              hasSavedCoordinates || (await countSavedCoordinateRecords()) > 0;
          if (recountCountdown >= _remainingCountEveryRows) {
            remainingMissing = await countPendingReports();
            recountCountdown = 0;
          }
          _setProgressState({
            'state': 'running',
            'running': true,
            'processed': processed,
            'updated': updated,
            'not_found': notFound,
            'remaining_missing': remainingMissing,
            'has_saved_coordinates': hasSavedCoordinates,
          });
        }

        await Future<void>.delayed(const Duration(milliseconds: 40));
      }

      if (cacheOnlyMode &&
          (await countPendingReports()) > 0 &&
          (await countCacheBackfillableReports()) <= 0) {
        final notice = await _missingApiKeyNotice();
        _setProgressState({
          'state': notice.state,
          'running': false,
          'processed': processed,
          'updated': updated,
          'not_found': notFound,
          'remaining_missing': await countPendingReports(),
          'error_message': notice.message,
          'finished_at': DateTime.now().millisecondsSinceEpoch,
          'has_saved_coordinates': notice.hasSavedCoordinates,
        });
        return;
      }

      _setProgressState({
        'state': 'completed',
        'running': false,
        'processed': processed,
        'updated': updated,
        'not_found': notFound,
        'remaining_missing': await countPendingReports(),
        'error_message': '',
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'has_saved_coordinates': hasSavedCoordinates,
      });
    } catch (exc) {
      _setProgressState({
        'state': 'error',
        'running': false,
        'processed': processed,
        'updated': updated,
        'not_found': notFound,
        'remaining_missing': await countPendingReports(),
        'error_message': '좌표 백필 중 오류가 발생했습니다: $exc',
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'has_saved_coordinates': hasSavedCoordinates,
      });
    }
  }

  static Future<void> _applyGeoPayload(
    String reportId,
    Map<String, Object?> payload,
  ) async {
    final d = await LocalDbService.db;
    await d.update(
      'reports',
      {
        '주소정규화': payload['주소정규화'] ?? '',
        '행정구역': payload['행정구역'] ?? '',
        '위도': payload['위도'],
        '경도': payload['경도'],
        '지오코딩상태': payload['지오코딩상태'] ?? '',
      },
      where: 'ID = ?',
      whereArgs: [reportId],
    );
  }

  static Future<Map<String, Object?>> resolveAddress(
    String apiKey,
    String address,
  ) async {
    final normalized = normalizeGeocodeAddress(address);
    if (normalized.isEmpty) {
      return buildPendingGeoPayload('', status: '');
    }

    final d = await LocalDbService.db;
    final cachedRows = await d.query(
      'geocode_cache',
      where: '주소정규화 = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (cachedRows.isNotEmpty) {
      final cached = cachedRows.first;
      final status = cached['상태']?.toString().trim() ?? '';
      if (status == 'ok' || status == 'not_found') {
        return {
          '주소정규화': normalizeGeocodeAddress(cached['주소정규화']?.toString()),
          '행정구역': cached['행정구역']?.toString().trim() ?? '',
          '위도': parseGeoDouble(cached['위도']),
          '경도': parseGeoDouble(cached['경도']),
          '지오코딩상태': status,
        };
      }
    }

    if (apiKey.trim().isEmpty) {
      throw GeocodeConfigurationError('모바일 설정에서 카카오 REST API 키를 입력하세요.');
    }

    late http.Response response;
    try {
      response = await http
          .get(
            Uri.parse(
              _kakaoAddressUrl,
            ).replace(queryParameters: {'query': normalized}),
            headers: {'Authorization': 'KakaoAK $apiKey'},
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException catch (_) {
      throw GeocodeProviderError('요청 시간이 초과되었습니다.');
    } on Exception catch (exc) {
      throw GeocodeProviderError(exc.toString());
    }

    if (response.statusCode != 200) {
      String message = '';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        message = body['message']?.toString() ?? '';
      } catch (_) {
        message = response.body;
      }
      throw GeocodeProviderError(
        'HTTP ${response.statusCode}${message.isEmpty ? '' : ' $message'}',
      );
    }

    Map<String, dynamic> payloadJson;
    try {
      payloadJson = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw GeocodeProviderError('카카오 응답을 해석하지 못했습니다.');
    }

    final documents = payloadJson['documents'] as List? ?? const [];
    if (documents.isEmpty) {
      final payload = {
        '주소정규화': normalized,
        '행정구역': '',
        '위도': null,
        '경도': null,
        '지오코딩상태': 'not_found',
      };
      await _persistCacheRecord(
        normalizedAddress: normalized,
        originalAddress: address,
        payload: payload,
        errorMessage: 'NOT_FOUND',
      );
      return payload;
    }

    final first = Map<String, dynamic>.from(documents.first as Map);
    final addressInfo = first['address'] is Map
        ? Map<String, dynamic>.from(first['address'] as Map)
        : const <String, dynamic>{};
    final roadInfo = first['road_address'] is Map
        ? Map<String, dynamic>.from(first['road_address'] as Map)
        : const <String, dynamic>{};
    final lng =
        parseGeoDouble(first['x']) ??
        parseGeoDouble(addressInfo['x']) ??
        parseGeoDouble(roadInfo['x']);
    final lat =
        parseGeoDouble(first['y']) ??
        parseGeoDouble(addressInfo['y']) ??
        parseGeoDouble(roadInfo['y']);
    if (lat == null || lng == null) {
      throw GeocodeProviderError('카카오 응답에 좌표 값이 없습니다.');
    }

    final payload = {
      '주소정규화': normalized,
      '행정구역': _extractRegionLabel(first),
      '위도': lat,
      '경도': lng,
      '지오코딩상태': 'ok',
    };
    await _persistCacheRecord(
      normalizedAddress: normalized,
      originalAddress: address,
      payload: payload,
    );
    return payload;
  }

  static String _extractRegionLabel(Map<String, dynamic> document) {
    for (final key in const ['road_address', 'address']) {
      final section = document[key];
      if (section is! Map) continue;
      final info = Map<String, dynamic>.from(section);
      final parts = [
        info['region_1depth_name']?.toString().trim() ?? '',
        info['region_2depth_name']?.toString().trim() ?? '',
        (info['region_3depth_name'] ?? info['region_3depth_h_name'])
                ?.toString()
                .trim() ??
            '',
      ].where((item) => item.isNotEmpty).toList();
      if (parts.isNotEmpty) {
        return parts.join(' ');
      }
    }
    return normalizeGeocodeAddress(document['address_name']?.toString());
  }

  static Future<void> _persistCacheRecord({
    required String normalizedAddress,
    required String originalAddress,
    required Map<String, Object?> payload,
    String errorMessage = '',
  }) async {
    final d = await LocalDbService.db;
    await d.insert('geocode_cache', {
      '주소정규화': normalizedAddress,
      '원본주소': normalizeGeocodeAddress(originalAddress),
      '행정구역': payload['행정구역'] ?? '',
      '위도': payload['위도'],
      '경도': payload['경도'],
      '상태': payload['지오코딩상태'] ?? '',
      'source': 'kakao',
      'error_message': errorMessage,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
