import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'network_retry_config.dart';
import 'server_contract.dart';

/// Setup / Settings 화면에서 공통으로 사용하는 Client 모드 서버 연결 검사.
/// 화면에 흩어져 있던 raw http + retry 루프 + status code 분기를 한 곳에 모은다.
class ServerConnectionService {
  ServerConnectionService._();

  /// `/api/v1/summary` 를 호출해 baseUrl/apiKey 가 유효한지 확인.
  ///
  /// 성공 시 [ServerConnectionResult.ok] 반환.
  /// 인증 실패는 [ServerConnectionResult.unauthorized],
  /// 그 외 HTTP 오류는 [ServerConnectionResult.httpError],
  /// 네트워크 / 타임아웃 / 파싱 실패는 [ServerConnectionResult.networkError].
  static Future<ServerConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
    Duration timeout = const Duration(seconds: 10),
    http.Client? client,
  }) async {
    final cleanUrl = ServerContract.normalizeBaseUrl(baseUrl);
    final ownedClient = client ?? http.Client();
    Object? lastError;
    http.Response? response;
    try {
      for (var attempt = 1; attempt <= mobileMaxRetryAttempts; attempt++) {
        try {
          response = await ownedClient
              .get(
                ServerContract.apiUri(cleanUrl, ServerContract.summaryPath),
                headers: ServerContract.apiHeaders(apiKey),
              )
              .timeout(timeout);
          break;
        } on SocketException catch (e) {
          lastError = e;
        } on http.ClientException catch (e) {
          lastError = e;
        } on TimeoutException catch (e) {
          lastError = e;
        }
        if (attempt < mobileMaxRetryAttempts) {
          await Future.delayed(
            const Duration(seconds: mobileRetryDelaySeconds),
          );
        }
      }
      if (response == null) {
        return ServerConnectionResult.networkError(
          normalizedUrl: cleanUrl,
          message: '네트워크 오류 ($mobileMaxRetryAttempts회 재시도 실패): $lastError',
        );
      }

      if (response.statusCode == 200) {
        try {
          jsonDecode(response.body);
          return ServerConnectionResult.ok(normalizedUrl: cleanUrl);
        } catch (_) {
          return ServerConnectionResult.networkError(
            normalizedUrl: cleanUrl,
            message: '서버 응답 파싱 실패. 올바른 서버인지 확인해주세요.',
          );
        }
      }
      if (response.statusCode == 401) {
        return ServerConnectionResult.unauthorized(normalizedUrl: cleanUrl);
      }
      return ServerConnectionResult.httpError(
        normalizedUrl: cleanUrl,
        statusCode: response.statusCode,
      );
    } finally {
      if (client == null) {
        ownedClient.close();
      }
    }
  }

  /// `/api/v1/version` 호출 → 서버 버전 정보. 실패 시 [ServerVersionInfo.empty].
  static Future<ServerVersionInfo> fetchVersionInfo({
    required String baseUrl,
    required String apiKey,
    Duration timeout = const Duration(seconds: 5),
    http.Client? client,
  }) async {
    final cleanUrl = ServerContract.normalizeBaseUrl(baseUrl);
    final headers = ServerContract.apiHeaders(
      apiKey,
      includeJsonContentType: false,
    );
    final ownedClient = client ?? http.Client();
    try {
      final res = await ownedClient
          .get(
            ServerContract.apiUri(cleanUrl, ServerContract.serverVersionPath),
            headers: headers,
          )
          .timeout(timeout);
      if (res.statusCode != 200) return ServerVersionInfo.empty;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final ver = j['version'] as String?;
      final latest = j['latest_version'] as String?;
      final upToDate = j['up_to_date'] as bool?;
      return ServerVersionInfo(
        version: ver,
        latestVersion: latest,
        status: upToDate == null
            ? null
            : (upToDate ? 'up_to_date' : 'outdated'),
      );
    } catch (_) {
      return ServerVersionInfo.empty;
    } finally {
      if (client == null) {
        ownedClient.close();
      }
    }
  }
}

enum ServerConnectionStatus { ok, unauthorized, httpError, networkError }

class ServerConnectionResult {
  final ServerConnectionStatus status;
  final String normalizedUrl;
  final int? statusCode;
  final String? message;

  const ServerConnectionResult._({
    required this.status,
    required this.normalizedUrl,
    this.statusCode,
    this.message,
  });

  factory ServerConnectionResult.ok({required String normalizedUrl}) =>
      ServerConnectionResult._(
        status: ServerConnectionStatus.ok,
        normalizedUrl: normalizedUrl,
      );

  factory ServerConnectionResult.unauthorized({
    required String normalizedUrl,
  }) => ServerConnectionResult._(
    status: ServerConnectionStatus.unauthorized,
    normalizedUrl: normalizedUrl,
    statusCode: 401,
    message: 'API Key 인증 실패 (401)',
  );

  factory ServerConnectionResult.httpError({
    required String normalizedUrl,
    required int statusCode,
  }) => ServerConnectionResult._(
    status: ServerConnectionStatus.httpError,
    normalizedUrl: normalizedUrl,
    statusCode: statusCode,
    message: '서버 오류: HTTP $statusCode',
  );

  factory ServerConnectionResult.networkError({
    required String normalizedUrl,
    required String message,
  }) => ServerConnectionResult._(
    status: ServerConnectionStatus.networkError,
    normalizedUrl: normalizedUrl,
    message: message,
  );

  bool get isOk => status == ServerConnectionStatus.ok;
}

class ServerVersionInfo {
  final String? version;
  final String? latestVersion;
  final String? status;
  const ServerVersionInfo({this.version, this.latestVersion, this.status});

  static const empty = ServerVersionInfo();
  bool get hasVersion => version != null && version!.isNotEmpty;
}
