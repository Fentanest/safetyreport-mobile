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
      await ServerContract.loadProductVersion();
      final response = await ownedClient
          .get(
            ServerContract.apiUri(cleanUrl, ServerContract.serverVersionPath),
            headers: ServerContract.apiHeaders(apiKey),
          )
          .timeout(timeout);
      if (const [401, 403].contains(response.statusCode)) {
        return ServerConnectionResult.unauthorized(normalizedUrl: cleanUrl);
      }
      if (response.statusCode == 404) {
        return ServerConnectionResult.incompatibleServer(
          normalizedUrl: cleanUrl,
        );
      }
      if (response.statusCode == 409) {
        final message = upgradeMessage(response.body);
        if (message != null) {
          return ServerConnectionResult.incompatibleServer(
            normalizedUrl: cleanUrl,
            message: message,
          );
        }
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
      if (version is! String ||
          !supportsServerVersion(version) ||
          body is! Map ||
          body['protocol_version'] != 3 ||
          body['supported_client_protocols'] is! List ||
          !(body['supported_client_protocols'] as List).contains(3)) {
        return ServerConnectionResult.incompatibleServer(
          normalizedUrl: cleanUrl,
        );
      }
      return ServerConnectionResult.ok(normalizedUrl: cleanUrl);
    } on HandshakeException {
      return ServerConnectionResult.networkError(
        normalizedUrl: cleanUrl,
        message: 'TLS 인증서 확인에 실패했습니다. 서버 인증서와 주소를 확인하세요.',
      );
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

      if (response.statusCode == 409) {
        final message = upgradeMessage(response.body);
        if (message != null) {
          return ServerConnectionResult.incompatibleServer(
            normalizedUrl: cleanUrl,
            message: message,
          );
        }
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
      if (const [401, 403].contains(response.statusCode)) {
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
      r'^v?([0-9]+)\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-(?:dev|alpha|beta|rc)[.\w-]*)?(?:\+[\w.-]+)?$',
    ).firstMatch(version.trim());
    if (match == null) return false;
    return (int.tryParse(match.group(1)!) ?? 0) >= 3;
  }

  static String? upgradeMessage(String body) {
    try {
      final json = jsonDecode(body);
      final detail = json is Map ? json['detail'] : null;
      final code = json is Map
          ? (json['code'] ?? (detail is Map ? detail['code'] : detail))
          : null;
      if (code == 'SERVER_UPGRADE_REQUIRED') {
        return 'PC 서버를 v3 이상으로 업데이트하세요.';
      }
      if (code == 'CLIENT_UPGRADE_REQUIRED') {
        return '모바일 앱을 최신 버전으로 업데이트하세요.';
      }
      if (code == 'CLIENT_PROTOCOL_UNSUPPORTED') {
        return '앱과 PC 서버의 통신 규약이 맞지 않습니다. protocol 3을 지원하는 앱과 서버로 업데이트하세요.';
      }
    } catch (_) {}
    return null;
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
    String? message,
  }) => ServerConnectionResult._(
    status: ServerConnectionStatus.incompatibleServer,
    normalizedUrl: normalizedUrl,
    message: message ?? 'PC 서버를 v3 이상으로 업데이트하고 self-host protocol 3 지원을 확인하세요.',
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
