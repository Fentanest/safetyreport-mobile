import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import 'community_store.dart';

/// One durable service cooldown shared by foreground and Workmanager isolates.
/// Only community HTTP clients use this transport; SafetyReport collection and
/// healthy OAuth requests keep their existing cadence.
class CloudAvailability extends ChangeNotifier {
  CloudAvailability(this.store, this.url, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  static CloudAvailability? shared;
  final CommunityStore store;
  final String url;
  final DateTime Function() now;
  String get key => 'cloud_availability:${projectNamespace(url)}';
  DateTime? nextAttemptAt;

  Future<DateTime?> deadline() async {
    final raw = await store.meta(key);
    nextAttemptAt = raw == null ? null : DateTime.tryParse(raw);
    return nextAttemptAt;
  }

  Future<bool> coolingDown() async {
    final at = await deadline();
    return at != null && now().isBefore(at);
  }

  Future<void> failed({double? retryAfterSeconds}) async {
    final until = now().add(
      Duration(
        milliseconds: (max(300.0, retryAfterSeconds ?? 0) * 1000).ceil(),
      ),
    );
    await store.transaction((tx) async {
      final old = DateTime.tryParse(await store.meta(key, tx) ?? '');
      final at = old != null && old.isAfter(until) ? old : until;
      await store.setMeta(key, isoUtc(at), tx);
      nextAttemptAt = at;
    });
    notifyListeners();
  }

  Future<void> ensureCooldown() async {
    if (!await coolingDown()) await failed();
  }

  Future<http.StreamedResponse> send(
    http.BaseRequest request,
    http.Client client,
  ) async {
    if (request.url.origin != Uri.parse(url).origin) {
      return client.send(request);
    }
    final at = await deadline();
    final probe = at != null;
    final owner = newUuidV4();
    if ((at != null && now().isBefore(at)) ||
        (probe &&
            !await store.acquireLease(
              '$key:probe',
              owner,
              const Duration(seconds: 45),
            ))) {
      return http.StreamedResponse(
        Stream.value(
          utf8.encode('{"error":{"code":"cloud_cooldown","retryable":true}}'),
        ),
        503,
        headers: {'retry-after': '${max(1, (at.difference(now()).inSeconds))}'},
        request: request,
      );
    }
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 32));
      // Read within the timeout too: headers arriving does not mean the body is healthy.
      final body = await response.stream.toBytes().timeout(
        const Duration(seconds: 32),
      );
      if (response.statusCode == 429 ||
          response.statusCode == 408 ||
          response.statusCode >= 500) {
        double? hint = retryAfter(response.headers['retry-after'], now());
        try {
          final decoded = jsonDecode(utf8.decode(body));
          final error = decoded is Map ? decoded['error'] : null;
          if (error is Map) {
            for (final field in ['retryAfterSeconds', 'retry_after_seconds']) {
              final seconds = error[field];
              if (seconds is num && seconds.isFinite && seconds >= 0) {
                hint = max(hint ?? 0, seconds.toDouble());
              }
            }
          }
        } catch (_) {}
        await failed(retryAfterSeconds: hint);
      } else if (probe) {
        // Do not clear a longer deadline recorded by another request.
        await store.transaction((tx) async {
          final current = await store.meta(key, tx);
          if (current == isoUtc(at)) {
            await tx.delete('meta', where: 'key=?', whereArgs: [key]);
            nextAttemptAt = null;
          }
        });
      }
      return http.StreamedResponse(
        Stream.value(body),
        response.statusCode,
        headers: response.headers,
        request: request,
        reasonPhrase: response.reasonPhrase,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
      );
    } catch (_) {
      await failed();
      rethrow;
    } finally {
      if (probe) await store.releaseLease('$key:probe', owner);
    }
  }
}

double? retryAfter(String? value, DateTime now) {
  if (value == null) return null;
  final seconds = double.tryParse(value.trim());
  if (seconds != null && seconds.isFinite) return max(0, seconds);
  try {
    return max(
      0,
      HttpDate.parse(value).difference(now.toUtc()).inMilliseconds / 1000,
    );
  } catch (_) {
    return null;
  }
}

class CloudHttpClient extends http.BaseClient {
  CloudHttpClient(this.inner);
  final http.Client inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      CloudAvailability.shared?.send(request, inner) ?? inner.send(request);
  @override
  void close() => inner.close();
}
