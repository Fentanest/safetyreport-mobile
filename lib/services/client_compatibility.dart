import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'server_connection_service.dart';
import 'server_contract.dart';

class ClientCompatibilityException implements Exception {
  final ServerConnectionResult result;
  const ClientCompatibilityException(this.result);
  @override
  String toString() => result.message ?? '서버 호환성을 확인할 수 없습니다.';
}

/// A short, memory-only lease scoped to the exact address AND key. Never persisted.
/// Single-flight avoids simultaneous probes; failures stay blocked until explicit retry.
class ClientCompatibility {
  static int _generation = 0;
  static String? _baseUrl;
  static String? _apiKey;
  static Future<ServerConnectionResult>? _pending;
  static ServerConnectionResult? _result;
  static DateTime? _checkedAt;
  static final failure = ValueNotifier<ServerConnectionResult?>(null);

  static void invalidate() {
    _generation++;
    _pending = null;
    _result = null;
    _checkedAt = null;
    failure.value = null;
  }

  static Future<void> ensure(
    String baseUrl,
    String apiKey, {
    http.Client? client,
  }) async {
    final url = ServerContract.normalizeBaseUrl(baseUrl);
    if (_baseUrl != url || _apiKey != apiKey) {
      invalidate();
      _baseUrl = url;
      _apiKey = apiKey;
    }
    var result = _result;
    if (result == null ||
        (result.isOk &&
            DateTime.now().difference(_checkedAt!) >
                const Duration(minutes: 1))) {
      final generation = _generation;
      final probe = _pending ??= ServerConnectionService.checkVersion(
        baseUrl: url,
        apiKey: apiKey,
        client: client,
      );
      result = await probe;
      // An old account/address probe cannot authorize a new connection.
      if (_baseUrl != url || _apiKey != apiKey || _generation != generation) {
        throw StateError('서버 설정이 변경되었습니다. 다시 연결하세요.');
      }
      _pending = null;
      _result = result;
      _checkedAt = DateTime.now();
    }
    if (!result.isOk) {
      failure.value = result;
      throw ClientCompatibilityException(result);
    }
  }

  static void reject(String baseUrl, String apiKey, String message) {
    block(baseUrl, apiKey, message);
    throw ClientCompatibilityException(
      ServerConnectionResult.incompatibleServer(
        normalizedUrl: ServerContract.normalizeBaseUrl(baseUrl),
        message: message,
      ),
    );
  }

  static void block(String baseUrl, String apiKey, String message) {
    if (_baseUrl != ServerContract.normalizeBaseUrl(baseUrl) ||
        _apiKey != apiKey) {
      return;
    }
    _result = ServerConnectionResult.incompatibleServer(
      normalizedUrl: _baseUrl!,
      message: message,
    );
    failure.value = _result;
  }
}
