import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import 'community_store.dart';

/// 연속 실패 점증의 기준값(초) — 첫 실패 300초, 2배씩, 상한 1800초(30분).
/// PC `community_upload_policy.py`·공용 원칙(cloud-retry-brief)과 같은 식: 300·2^(n-1).
const int cloudBaseRetrySeconds = 300;
const int cloudMaxRetrySeconds = 1800;

/// 점증 기준값에 적용하는 균등 지터 비율(±20%).
const double cloudJitterFraction = 0.2;

/// 연속 실패 n(1부터)에 대한 점증 쿨다운 기준값(지터 적용 전, 상한 1800초).
double escalatedCooldownBaseSeconds(int consecutiveFailures) {
  var seconds = cloudBaseRetrySeconds.toDouble();
  var remaining = consecutiveFailures - 1;
  while (remaining > 0 && seconds < cloudMaxRetrySeconds) {
    seconds *= 2;
    remaining--;
  }
  return min(seconds, cloudMaxRetrySeconds.toDouble());
}

/// One durable service cooldown shared by foreground and Workmanager isolates.
/// Only community HTTP clients use this transport; SafetyReport collection and
/// healthy OAuth requests keep their existing cadence.
class CloudAvailability extends ChangeNotifier {
  CloudAvailability(
    this.store,
    this.url, {
    DateTime Function()? now,
    Random? random,
  }) : now = now ?? DateTime.now,
       random = random ?? Random();
  static CloudAvailability? shared;
  final CommunityStore store;
  final String url;
  final DateTime Function() now;

  /// 지터 난수원. 실제 실행은 기기마다 다른 지터를 내도록 기본 `Random()`을 쓰고,
  /// 시험은 고정값을 주입해 쿨다운 시각을 결정적으로 만든다.
  final Random random;
  String get key => 'cloud_availability:${projectNamespace(url)}';

  /// 연속 실패 횟수 영속 키(마감과 함께 쓰고 지운다 — 성공하면 둘 다 지워 n=0).
  String get _failuresKey => '$key:failures';
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

  /// 현재까지 기록된 연속 실패 횟수(진단·시험용). 성공하면 0으로 돌아간다.
  Future<int> consecutiveFailures() async =>
      int.tryParse(await store.meta(_failuresKey) ?? '0') ?? 0;

  double _withJitter(double seconds) {
    final factor = 1 + (random.nextDouble() * 2 - 1) * cloudJitterFraction;
    return seconds * factor;
  }

  Future<void> failed({double? retryAfterSeconds}) async {
    await store.transaction((tx) async {
      final failures =
          (int.tryParse(await store.meta(_failuresKey, tx) ?? '0') ?? 0) + 1;
      final escalated = _withJitter(escalatedCooldownBaseSeconds(failures));
      final until = now().add(
        Duration(
          milliseconds: (max(escalated, retryAfterSeconds ?? 0) * 1000).ceil(),
        ),
      );
      final old = DateTime.tryParse(await store.meta(key, tx) ?? '');
      final at = old != null && old.isAfter(until) ? old : until;
      await store.setMeta(key, isoUtc(at), tx);
      await store.setMeta(_failuresKey, '$failures', tx);
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
            // 성공하면 연속 실패 횟수도 0으로(같은 마감을 지울 때만 — 그 사이 다른 실패가
            // 새 마감을 썼으면 그 실패 횟수를 지우지 않는다).
            await tx.delete('meta', where: 'key=?', whereArgs: [_failuresKey]);
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
