import 'package:http/http.dart' as http;
import 'client_compatibility.dart';
import 'server_contract.dart';

/// Attachments can point to government/CDN hosts. Never disclose server keys to
/// those hosts. The self-host origin uses the same gate as API and downloads.
class ClientMediaAccess {
  static bool isServerOrigin(String url, String baseUrl) {
    final media = Uri.tryParse(url), server = Uri.tryParse(baseUrl);
    return media != null &&
        server != null &&
        server.host.isNotEmpty &&
        media.scheme == server.scheme &&
        media.host == server.host &&
        media.port == server.port;
  }

  static Future<Map<String, String>?> headers(
    String url, {
    required String baseUrl,
    required String apiKey,
    http.Client? client,
  }) async {
    if (!isServerOrigin(url, baseUrl)) return null;
    await ClientCompatibility.ensure(baseUrl, apiKey, client: client);
    return ServerContract.apiHeaders(apiKey, includeJsonContentType: false);
  }
}
