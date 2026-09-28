// 기관·지역 registry 런타임 스냅샷 (shared/agency-region-registry).
//
// PC `services/agency_registry.py` 와 같은 규칙: 원문 기관코드·기관명은 사실로
// 보존하고, 통계·표시용 현행명과 통계 키는 이 스냅샷에서만 계산한다.
// 확인된 코드(현존·승계·별칭 유일)는 현행명 + agency_stat_key, (구) 분기는
// '(구)' 표시 + 별도 src 키, 미확정은 기존 normalize 로 호출자가 폴백한다.
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
  AgencyRegistrySnapshot snap,
) {
  final cleanName = (name ?? '').trim();
  final displayName = cleanName.isEmpty ? null : cleanName;
  if (_isSevenAlnum(code)) {
    final c = code!;
    final row = snap.index[c] as List?;
    if (row != null) {
      return _resolveBoundary(row[1] as String, displayName, answeredAt, snap, c);
    }
    final target = snap.forward[c] as String?;
    if (target != null) {
      return _resolveBoundary(target, displayName, answeredAt, snap, c);
    }
    if ((snap.multi as Map).containsKey(c)) {
      final display = displayName != null ? '(구)$displayName' : '(구)${snap.multi[c]}';
      return {
        'institution_id': null,
        'agency_stat_key': 'src:$c:${displayName ?? '-'}',
        'current_agency_code': null,
        'current_agency_name': display,
        'resolution_status': 'historical',
        'registry_version': snap.registryVersion,
      };
    }
    return {
      'institution_id': null,
      'agency_stat_key': 'src:$c:${displayName ?? '-'}',
      'current_agency_code': null,
      'current_agency_name': displayName,
      'resolution_status': 'unresolved',
      'registry_version': snap.registryVersion,
    };
  }
  if (displayName != null) {
    final candidates = _aliasCandidates(displayName, answeredAt, snap);
    if (candidates.length == 1) {
      final got = Map<String, dynamic>.from(
        _resolveAgency(candidates.first, displayName, answeredAt, snap),
      );
      got['code_derived'] = true;
      return got;
    }
  }
  return {
    'institution_id': null,
    'agency_stat_key': 'src:${code ?? '-'}:${displayName ?? '-'}',
    'current_agency_code': null,
    'current_agency_name': displayName,
    'resolution_status': 'unresolved',
    'registry_version': snap.registryVersion,
  };
}

List<dynamic> _walkChain(String start, AgencyRegistrySnapshot snap) {
  final byFrom = <String, List<dynamic>>{};
  final byTo = <String, List<dynamic>>{};
  for (final l in snap.links) {
    (byFrom[l['from_code'] as String] ??= []).add(l);
    (byTo[l['to_code'] as String] ??= []).add(l);
  }
  final chain = <dynamic>[];
  final seen = <String>{start};
  while (true) {
    final from = chain.isEmpty ? start : chain.last['to_code'] as String;
    final outgoing = byFrom[from] ?? const [];
    if (outgoing.length != 1) break;
    final next = outgoing.first;
    if (seen.contains(next['to_code'])) break;
    chain.add(next);
    seen.add(next['to_code'] as String);
  }
  if (chain.isEmpty) {
    final back = <dynamic>[];
    var cursor = start;
    while (true) {
      final incoming = byTo[cursor] ?? const [];
      if (incoming.length != 1) break;
      final link = incoming.first;
      if (seen.contains(link['from_code'])) break;
      back.add(link);
      seen.add(link['from_code'] as String);
      cursor = link['from_code'] as String;
    }
    chain.addAll(back.reversed);
  }
  return chain;
}

String? _boundaryName(String boundary, AgencyRegistrySnapshot snap) {
  final row = snap.index[boundary] as List?;
  final name = row == null ? null : row[0] as String?;
  return (name == null || name.isEmpty) ? null : name;
}

Map<String, dynamic> _resolveBoundary(
  String boundary,
  String? name,
  String? answeredAt,
  AgencyRegistrySnapshot snap,
  String? asWasCode,
) {
  final chain = _walkChain(boundary, snap);
  final mapped = snap.institutions[boundary] as String?;
  if (chain.isEmpty) {
    final institutionId = mapped ?? 'ag-c${boundary.toLowerCase()}';
    return {
      'institution_id': institutionId,
      'agency_stat_key': 'inst:$institutionId',
      'current_agency_code': boundary,
      'current_agency_name': _boundaryName(boundary, snap) ?? name,
      'resolution_status': 'resolved',
      'registry_version': snap.registryVersion,
    };
  }
  final institutionId =
      mapped ?? (chain.first['institution_id'] as String?) ?? 'ag-c${boundary.toLowerCase()}';
  final horizon = answeredAt ?? '9999-12-31';
  final applied = chain
      .where((l) => horizon.compareTo(l['effective_date'] as String) >= 0)
      .toList();
  if (applied.length == chain.length) {
    final head = chain.last['to_code'] as String;
    return {
      'institution_id': institutionId,
      'agency_stat_key': 'inst:$institutionId',
      'current_agency_code': head,
      'current_agency_name':
          _boundaryName(head, snap) ?? (chain.last['to_name'] as String?) ?? name,
      'resolution_status': 'resolved',
      'registry_version': snap.registryVersion,
    };
  }
  final anchor = applied.isEmpty ? null : applied.last;
  if (anchor == null) {
    return {
      'institution_id': institutionId,
      'agency_stat_key': 'inst:$institutionId',
      'current_agency_code': _isSevenAlnum(asWasCode) ? asWasCode : null,
      'current_agency_name': name,
      'resolution_status': 'resolved_as_of_date',
      'registry_version': snap.registryVersion,
    };
  }
  return {
    'institution_id': institutionId,
    'agency_stat_key': 'inst:$institutionId',
    'current_agency_code': anchor['to_code'],
    'current_agency_name': (anchor['to_name'] as String?) ?? name,
    'resolution_status': 'resolved_as_of_date',
    'registry_version': snap.registryVersion,
  };
}

List<String> _aliasCandidates(
  String name,
  String? answeredAt,
  AgencyRegistrySnapshot snap,
) {
  final digits = (answeredAt ?? '').replaceAll('-', '');
  final ans8 = digits.length >= 8 ? digits.substring(0, 8) : null;
  final found = <String>[];
  for (final code in snap.aliasAll(name)) {
    final row = snap.index[code] as List?;
    final created = (row == null ? null : row[3] as String?) ?? '';
    if (ans8 != null && created.isNotEmpty && created.compareTo(ans8) > 0) {
      continue;
    }
    found.add(code);
  }
  return found;
}

/// Vendored from shared/.../resolvers/resolve.dart `displayAgency` (동결 복사).
String? _displayAgency(String? sourceName, Map<String, dynamic> resolution) {
  final status = resolution['resolution_status'];
  if (status == 'resolved' ||
      status == 'resolved_as_of_date' ||
      status == 'historical') {
    return resolution['current_agency_name'] as String?;
  }
  final clean = (sourceName ?? '').trim();
  return clean.isEmpty ? null : clean;
}

/// 동기 표시 계산에 쓰는 로드된 스냅샷.
class AgencyRegistrySnapshot {
  AgencyRegistrySnapshot({
    required this.links,
    required this.index,
    required this.forward,
    required this.multi,
    required this.institutions,
    required this.registryVersion,
    required this.asOfDate,
  });

  final List<dynamic> links;
  final Map<String, dynamic> index;
  final Map<String, dynamic> forward;
  final Map<String, dynamic> multi;
  final Map<String, dynamic> institutions;
  final String registryVersion;
  final String asOfDate;

  Map<String, List<String>>? _aliasAll;

  /// 스냅샷별 별칭 캐시: 8만 행 스캔을 매 신고마다 반복하지 않는다.
  List<String> aliasAll(String name) {
    var table = _aliasAll;
    if (table == null) {
      table = <String, List<String>>{};
      (index as Map).forEach((code, row) {
        final r = row as List;
        if (r[0] != null) {
          (table![r[0] as String] ??= []).add(code as String);
        }
      });
      (multi as Map).forEach((old, oldName) {
        final list = table![oldName as String] ??= [];
        if (!list.contains(old)) list.add(old as String);
      });
      _aliasAll = table;
    }
    return table[name] ?? const [];
  }

  /// 현행 표시명. 확인된 코드면 현행명, 아니면 null(호출자가 normalize 로 폴백).
  @visibleForTesting
  Map<String, dynamic> resolveForTest(
    String? code,
    String? name,
    String? answeredAt,
  ) => _resolveAgency(code, name, answeredAt, this);

  String? displayCurrentAgency(String? code, String? name) {    final resolution = _resolveAgency(
      code,
      name,
      asOfDate,
      this,
    );
    if (resolution['resolution_status'] != 'resolved') return null;
    final current = _displayAgency(name, resolution);
    if (current == null || current.trim().isEmpty) return null;
    return current;
  }

  /// 현행 표시명 + 통계 키. 스냅샷 미로드가 아니라면 항상 값을 낸다
  /// (미확정은 원문 표시 + src 키 — PC `_apply_registry_agency_display` 와 같은 규칙).
  ({String display, String key}) resolveKeyedAgency(String? code, String? name) {
    final trimmed = (name ?? '').trim();
    final resolution = _resolveAgency(code, trimmed, asOfDate, this);
    final status = resolution['resolution_status'];
    if (status == 'resolved' || status == 'resolved_as_of_date') {
      final current = _displayAgency(trimmed, resolution) ?? '';
      if (current.trim().isNotEmpty) {
        return (display: current, key: resolution['agency_stat_key'] as String);
      }
    }
    if (status == 'historical') {
      return (
        display: (resolution['current_agency_name'] as String?) ?? trimmed,
        key: resolution['agency_stat_key'] as String,
      );
    }
    // unresolved → 호출자가 원문 표시와 src 키를 적용한다.
    return (display: trimmed, key: '');
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
      final rows =
          (jsonDecode(await rootBundle.loadString(
                'shared/agency-region-registry/data/agency_index.json',
              ))
              as Map<String, dynamic>)['rows'] as List;
      // resolve.dart 규격: index 행은 [name, agg, type, created](코드 제외).
      final index = <String, dynamic>{
        for (final r in rows) (r as List).first as String: (r as List).sublist(1),
      };
      final legacy =
          jsonDecode(await rootBundle.loadString(
                'shared/agency-region-registry/data/agency_legacy.json',
              ))
              as Map<String, dynamic>;
      final institutions =
          (jsonDecode(await rootBundle.loadString(
                'shared/agency-region-registry/data/agency_institutions.json',
              ))
              as Map<String, dynamic>)['institutions'] as Map;
      _loaded = AgencyRegistrySnapshot(
        links: links,
        index: index,
        forward: Map<String, dynamic>.from(legacy['forward'] as Map),
        multi: Map<String, dynamic>.from(legacy['multi'] as Map),
        institutions: Map<String, dynamic>.from(institutions),
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

  /// 동기 표시+키: 스냅샷 미로드면 null(호출자가 원문+src 키로 폴백).
  static ({String display, String key})? resolveKeyedAgencyOrNull(
    String? code,
    String? name,
  ) {
    final snap = _loaded;
    if (snap == null) return null;
    return snap.resolveKeyedAgency(code, name);
  }

  @visibleForTesting
  static void testInject(AgencyRegistrySnapshot? snapshot) {
    _loaded = snapshot;
  }
}
