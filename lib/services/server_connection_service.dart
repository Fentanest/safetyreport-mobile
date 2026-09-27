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

  /// 저장된 Client 설정도 앱에 들어가기 전에 검사한다. 버전을 확인할 수 없으면 진입을 허용하지 않는다.
  static Future<ServerConnectionResult> checkVersion({
    required String baseUrl,
    required String apiKey,
    Duration timeout = const Duration(seconds: 10),
    http.Client? client,
  }) async {
    final cleanUrl = ServerContract.normalizeBaseUrl(baseUrl);
    final ownedClient = client ?? http.Client();
    try {
      final response = await ownedClient
          .get(
            ServerContract.apiUri(cleanUrl, ServerContract.serverVersionPath),
            headers: ServerContract.apiHeaders(apiKey),
          )
          .timeout(timeout);
      if (response.statusCode == 401) {
        return ServerConnectionResult.unauthorized(normalizedUrl: cleanUrl);
      }
      if (response.statusCode == 404) {
        return ServerConnectionResult.incompatibleServer(
          normalizedUrl: cleanUrl,
        );
      }
      if (response.statusCode != 200) {
        return ServerConnectionResult.httpError(
          normalizedUrl: cleanUrl,
          statusCode: response.statusCode,
        );
      }
      Object? body;
      try {
        body = jsonDecode(response.body);
      } catch (_) {
        return ServerConnectionResult.incompatibleServer(
          normalizedUrl: cleanUrl,
        );
      }
      final version = body is Map<String, dynamic> ? body['version'] : null;
      if (version is! String || !supportsServerVersion(version)) {
        return ServerConnectionResult.incompatibleServer(
          normalizedUrl: cleanUrl,
        );
      }
      return ServerConnectionResult.ok(normalizedUrl: cleanUrl);
    } on SocketException catch (e) {
      return ServerConnectionResult.networkError(
        normalizedUrl: cleanUrl,
        message: '서버 버전 확인 실패: $e',
      );
    } on http.ClientException catch (e) {
      return ServerConnectionResult.networkError(
        normalizedUrl: cleanUrl,
        message: '서버 버전 확인 실패: $e',
      );
    } on TimeoutException {
      return ServerConnectionResult.networkError(
        normalizedUrl: cleanUrl,
        message: '서버 버전 확인 시간이 초과되었습니다.',
      );
    } catch (_) {
      return ServerConnectionResult.networkError(
        normalizedUrl: cleanUrl,
        message: '서버 버전을 확인할 수 없습니다.',
      );
    } finally {
      if (client == null) ownedClient.close();
    }
  }

  /// `/api/v1/summary` 와 `/api/v1/server/version` 으로 인증과 호환성을 확인.
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
      final compatibility = await checkVersion(
        baseUrl: cleanUrl,
        apiKey: apiKey,
        timeout: timeout,
        client: ownedClient,
      );
      if (!compatibility.isOk) return compatibility;
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

  /// 서버 릴리스 버전의 major가 3 이상인지 확인한다. 알 수 없는 버전은 거절한다.
  static bool supportsServerVersion(String version) {
    final match = RegExp(
      r'^v?([0-9]+)(?:\.[0-9]+){2,3}(?:[-+][0-9A-Za-z.-]+)?$',
    ).firstMatch(version.trim());
    if (match == null) return false;
    return (int.tryParse(match.group(1)!) ?? 0) >= 3;
  }

  /// `/api/v1/server/version` 호출 → 서버 버전 정보. 실패 시 [ServerVersionInfo.empty].
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

enum ServerConnectionStatus {
  ok,
  unauthorized,
  incompatibleServer,
  httpError,
  networkError,
}

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

  factory ServerConnectionResult.incompatibleServer({
    required String normalizedUrl,
  }) => ServerConnectionResult._(
    status: ServerConnectionStatus.incompatibleServer,
    normalizedUrl: normalizedUrl,
    message: '이 PC 서버 버전은 모바일 앱 v2와 호환되지 않습니다. PC 앱을 v3 이상으로 업데이트하세요.',
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
