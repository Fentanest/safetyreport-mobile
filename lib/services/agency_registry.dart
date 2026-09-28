// 기관·지역 registry 런타임 스냅샷 (shared/agency-region-registry).
//
// PC `services/agency_registry.py` 와 같은 규칙: 원문 기관코드·기관명은 사실로
// 보존하고, 통계·표시용 현행명은 이 스냅샷에서만 계산한다. 확인된 1:1 승계만
// 현행명으로 바꾸고, 미확정·미로드는 기존 normalize 로 호출자가 폴백한다.
// REVIEW2 높음-3: 테스트에서만 읽던 snapshot 을 앱 asset 으로 번들하고 실제
// 표시·집계 경로(local_db_service 통계·지도·조회)에 연결한다.
//
// NOTE: lib/ 안의 파일은 analyzer 제한으로 lib/ 밖(shared/)을 import 할 수
// 없어, 아래 `_resolveAgency`·`_displayAgency` 는
// `shared/agency-region-registry/resolvers/resolve.dart` 의 동결 복사본이다.
// 동작 동등성은 test/storage/agency_registry_wiring_test.dart 의 parity
// 테스트가 벡터 전건으로 강제한다. 정본을 고치면 여기도 같이 고친다.
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

bool _isSevenAlnum(String? code) {
  if (code == null || code.length != 7) return false;
  for (var i = 0; i < 7; i++) {
    final c = code.codeUnitAt(i);
    final ok = (c >= 48 && c <= 57) ||
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122);
    if (!ok) return false;
  }
  return true;
}

/// Vendored from shared/.../resolvers/resolve.dart `resolveAgency` (동결 복사).
Map<String, dynamic> _resolveAgency(
  String? code,
  String? name,
  String? answeredAt,
  List<dynamic> links,
  String registryVersion,
) {
  final cleanName = (name ?? '').trim();
  final displayName = cleanName.isEmpty ? null : cleanName;
  final byFrom = <String, List<dynamic>>{};
  for (final l in links) {
    (byFrom[l['from_code'] as String] ??= []).add(l);
  }
  final chain = <dynamic>[];
  if (_isSevenAlnum(code)) {
    final seen = <String>{code!};
    while (true) {
      final from = chain.isEmpty ? code : chain.last['to_code'] as String;
      final outgoing = byFrom[from] ?? const [];
      if (outgoing.length != 1) break;
      final next = outgoing.first;
      if (seen.contains(next['to_code'])) break;
      chain.add(next);
      seen.add(next['to_code'] as String);
    }
  }
  if (chain.isEmpty) {
    return {
      'institution_id': null,
      'agency_stat_key': 'src:${code ?? '-'}:${displayName ?? '-'}',
      'current_agency_code': null,
      'current_agency_name': displayName,
      'resolution_status': 'unresolved',
      'registry_version': registryVersion,
    };
  }
  final institutionId = chain.first['institution_id'];
  final horizon = answeredAt ?? '9999-12-31';
  final applied = chain
      .where((l) => horizon.compareTo(l['effective_date'] as String) >= 0)
      .toList();
  if (applied.length == chain.length) {
    final current = chain.last;
    return {
      'institution_id': institutionId,
      'agency_stat_key': 'inst:$institutionId',
      'current_agency_code': current['to_code'],
      'current_agency_name': current['to_name'],
      'resolution_status': 'resolved',
      'registry_version': registryVersion,
    };
  }
  final anchor = applied.isEmpty ? null : applied.last;
  return {
    'institution_id': institutionId,
    'agency_stat_key': 'inst:$institutionId',
    'current_agency_code': anchor == null ? code : anchor['to_code'],
    'current_agency_name': anchor == null ? displayName : anchor['to_name'],
    'resolution_status': 'resolved_as_of_date',
    'registry_version': registryVersion,
  };
}

/// Vendored from shared/.../resolvers/resolve.dart `displayAgency` (동결 복사).
String? _displayAgency(String? sourceName, Map<String, dynamic> resolution) {
  final status = resolution['resolution_status'];
  if (status == 'resolved' || status == 'resolved_as_of_date') {
    return resolution['current_agency_name'] as String?;
  }
  final clean = (sourceName ?? '').trim();
  return clean.isEmpty ? null : clean;
}

/// 동기 표시 계산에 쓰는 로드된 스냅샷.
class AgencyRegistrySnapshot {
  AgencyRegistrySnapshot({
    required this.links,
    required this.events,
    required this.registryVersion,
    required this.asOfDate,
  });

  final List<dynamic> links;
  final List<dynamic> events;
  final String registryVersion;
  final String asOfDate;

  /// 현행 표시명. 확인된 승계면 현행명, 아니면 null(호출자가 normalize 로 폴백).
  String? displayCurrentAgency(String? code, String? name) {
    final resolution = _resolveAgency(
      code,
      name,
      asOfDate,
      links,
      registryVersion,
    );
    if (resolution['resolution_status'] != 'resolved') return null;
    final current = _displayAgency(name, resolution);
    if (current == null || current.trim().isEmpty) return null;
    return current;
  }
}

class AgencyRegistry {
  static AgencyRegistrySnapshot? _loaded;

  /// 앱 시작 때 한 번 로드한다(main). 실패하면 null 로 두고 호출자가 폴백한다.
  static Future<void> ensureLoaded() async {
    if (_loaded != null) return;
    try {
      final manifest = jsonDecode(
        await rootBundle.loadString(
          'shared/agency-region-registry/manifest.json',
        ),
      ) as Map<String, dynamic>;
      final links =
          (jsonDecode(await rootBundle.loadString(
                'shared/agency-region-registry/data/agency_links.json',
              ))
              as Map<String, dynamic>)['links'] as List;
      final events =
          (jsonDecode(await rootBundle.loadString(
                'shared/agency-region-registry/data/region_events.json',
              ))
              as Map<String, dynamic>)['events'] as List;
      _loaded = AgencyRegistrySnapshot(
        links: links,
        events: events,
        registryVersion: manifest['registry_version'] as String,
        asOfDate: manifest['as_of_date'] as String,
      );
    } catch (_) {
      _loaded = null;
    }
  }

  /// 동기 표시: 스냅샷 미로드·미확정이면 null.
  static String? displayCurrentAgencyOrNull(String? code, String? name) =>
      _loaded?.displayCurrentAgency(code, name);

  @visibleForTesting
  static void testInject(AgencyRegistrySnapshot? snapshot) {
    _loaded = snapshot;
  }
}
