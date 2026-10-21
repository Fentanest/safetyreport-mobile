import 'dart:convert';
import 'client_server_policy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_prefs_keys.dart';
import '../services/community_server_link_service.dart';

/// API refusals are scoped to an exact PC address/key; stale replies cannot lock another server.
class ClientServerConsent {
  static final changed = ValueNotifier<int>(0);
  static String? _scope;
  static String fingerprint(String base, String key) =>
      sha256.convert(utf8.encode('$base\u0000$key')).toString();
  static void rejected(String base, String key) {
    _scope = fingerprint(base, key);
    changed.value++;
  }

  static bool matches(String base, String key) =>
      _scope == fingerprint(base, key);
  static bool permits(Map<String, dynamic>? data) => serverConsentAllows(data);
  static ServerConsentVerdict verdict(CommunityGateLinkResult result) =>
      serverConsentVerdict(
        result.data,
        onboardingRequired: result.needsOnboarding,
      );

  /// Asks the PC. Only an explicit refusal locks; a missing configuration, a network failure or a
  /// timeout is [ServerConsentVerdict.unknown]. A stale answer (address/key/lock stamp changed
  /// meanwhile) is unknown too: it must not lock or unlock another server.
  static Future<ServerConsentVerdict> verify(
    SharedPreferences prefs, {
    Future<CommunityGateLinkResult> Function()? fetch,
  }) async {
    try {
      final base = prefs.getString(AppPrefsKeys.baseUrl) ?? '',
          key = prefs.getString(AppPrefsKeys.apiKey) ?? '';
      if (fetch == null && (base.isEmpty || key.isEmpty)) {
        return ServerConsentVerdict.unknown;
      }
      final stamp = prefs.getInt('community_server_consent_lock') ?? 0;
      final result =
          await (fetch?.call() ??
              CommunityServerLinkService.fetchCommunityGate(
                baseUrl: base,
                apiKey: key,
              ));
      await prefs.reload();
      if ((prefs.getString(AppPrefsKeys.baseUrl) ?? '') != base ||
          (prefs.getString(AppPrefsKeys.apiKey) ?? '') != key ||
          (prefs.getInt('community_server_consent_lock') ?? 0) != stamp) {
        return ServerConsentVerdict.unknown;
      }
      final v = verdict(result);
      if (v == ServerConsentVerdict.permitted) {
        await prefs.remove('community_server_consent_lock');
      }
      return v;
    } catch (_) {
      return ServerConsentVerdict.unknown;
    }
  }
}
