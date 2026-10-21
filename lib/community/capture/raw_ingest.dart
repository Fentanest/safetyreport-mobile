import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'canonical_json.dart';

bool rawV2Ready(Map<String, Object?> status) {
  final consent = status['consent'], ingest = status['ingest'];
  return consent is Map &&
      ingest is Map &&
      consent['state'] == 'active' &&
      ingest['contracts'] is List &&
      (ingest['contracts'] as List).contains(2) &&
      ingest['raw_policy_version'] is String &&
      consent['policy_version'] == ingest['raw_policy_version'];
}

/// Only capability and consent scope are kept: no account names or remote dataset metadata.
Map<String, Object?> cachedIngestStatus(Map<String, Object?> status) {
  final consent = status['consent'], ingest = status['ingest'];
  return {
    'consent': {
      for (final k in ['state', 'grant_id', 'policy_version'])
        k: consent is Map ? consent[k] : null,
    },
    'ingest': {
      for (final k in ['contracts', 'raw_policy_version'])
        k: ingest is Map ? ingest[k] : null,
    },
  };
}

String rawCanonicalHash(Map<String, Object?> value) =>
    sha256.convert(utf8.encode(canonicalJson(value))).toString();
Map<String, Object?> rawSnapshot(
  String body,
  String fetchedAt,
  String source,
  Map<String, Object?> fields,
) {
  final decoded = jsonDecode(body);
  if (decoded is! Map || decoded['result'] is! Map) {
    throw const FormatException('raw_invalid');
  }
  final result = decoded['result'] as Map;
  if ([
    'C_NAME',
    'C_EMAIL',
    'C_PHONE',
    'C_PHONE2',
    'C_ID',
  ].any(result.containsKey)) {
    throw const FormatException('raw_reporter_keys_present');
  }
  // Supplement values are normalised to the schema ranges so a stray value (rating 0/6, an over-long
  // title) can never turn into a 422 and a dead letter: out-of-range numbers become null, strings are
  // cut to the schema length.
  Object? raw(String key) => fields[key] == '' ? null : fields[key];
  int? integer(String key, int min, int max) {
    final v = raw(key);
    final n = v is num
        ? v.toInt()
        : (v is String ? int.tryParse(v.trim()) : null);
    return n == null || n < min || n > max ? null : n;
  }

  String? text(String key, int max) {
    final v = raw(key);
    if (v == null) return null;
    final t = v.toString().replaceAll('\u0000', '');
    if (t.isEmpty) return null;
    final runes = t.runes.toList();
    return runes.length <= max ? t : String.fromCharCodes(runes.take(max));
  }

  final supplement = <String, Object?>{
    'rating': integer('별점', 1, 5),
    'rating_cause': text('별점사유', 10000),
    'survey_state': text('만족도조사여부', 80),
    'photo_first_at': text('사진_첫촬영', 80),
    'photo_last_at': text('사진_끝촬영', 80),
    'photo_count': integer('사진_촬영수', 0, 1000000),
    'list': <String, Object?>{
      'title': text('신고명', 1000),
      'report_date': text('신고일', 80),
      'status': text('상태', 80),
      'entry_value': text('entry_value', 200),
      'ssnpc_cd': text('ssnpc_cd', 32),
      'ssnpc_type': text('ssnpc_type', 32),
    },
  };
  return {
    'raw': <String, Object?>{
      'body': body,
      'sha256': sha256.convert(utf8.encode(body)).toString(),
      'size': utf8.encode(body).length,
      'fetched_at': fetchedAt,
      'source': source,
    },
    'supplement': supplement,
    'supplement_sha256': rawCanonicalHash(supplement),
  };
}

Map<String, Object?> rawWithObservation(
  Map<String, Object?> raw,
  Map<String, Object?> observation,
) => {
  ...raw,
  'client_observation': observation,
  'client_observation_sha256': rawCanonicalHash(observation),
};
List<Object?> rawContentKey(Map raw) => [
  (raw['raw'] as Map?)?['sha256'],
  raw['supplement_sha256'],
  raw['client_observation_sha256'],
];

String rawContractScope(Map<String, Object?> context) => [
  'contributor_fingerprint',
  'dataset_key',
  'consent_grant_id',
].map((k) => context[k] ?? '').join('|');

/// The part of a stored raw event that [rawContentKey] reads (hashes only).
String? compactRawEvent(String json) {
  try {
    final event = (jsonDecode(json) as Map).cast<String, Object?>();
    if (event['compact'] == true) return null;
    return jsonEncode({
      'compact': true,
      'raw': {'sha256': (event['raw'] as Map?)?['sha256']},
      'supplement_sha256': event['supplement_sha256'],
      'client_observation_sha256': event['client_observation_sha256'],
    });
  } catch (_) {
    return null;
  }
}
