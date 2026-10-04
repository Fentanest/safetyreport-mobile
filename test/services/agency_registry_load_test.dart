// SQ-P12: 기관 registry 를 앱 시작 때 읽는 경로(asset → isolate 해석)가 원본 JSON 과 같은 스냅샷을 만드는지.
// 문자열을 UI isolate 에서 만든 뒤 넘기던 방식을 바이트 전달로 바꿔도 색인·링크·버전이 한 글자도 달라지지 않아야 한다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/agency_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ensureLoaded builds the same snapshot as the shared JSON files',
    () async {
      AgencyRegistry.testInject(null);
      addTearDown(() => AgencyRegistry.testInject(null));
      await AgencyRegistry.ensureLoaded();
      final loaded = AgencyRegistry.cacheVersion as AgencyRegistrySnapshot?;
      expect(loaded, isNotNull);

      dynamic load(String name) => jsonDecode(
        File('shared/agency-region-registry/$name').readAsStringSync(),
      );
      final manifest = load('manifest.json') as Map<String, dynamic>;
      final indexBlob = load('data/agency_index.json') as Map<String, dynamic>;
      final legacy = load('data/agency_legacy.json') as Map<String, dynamic>;
      final index = <String, dynamic>{
        for (final r in indexBlob['rows'] as List)
          (r as List).first as String: r.sublist(1),
      };
      final compact = <String, dynamic>{
        for (final r in indexBlob['compact_rows'] as List)
          (r as List)[0] as String: r[1],
      };

      final snap = loaded!;
      expect(snap.registryVersion, manifest['registry_version']);
      expect(snap.asOfDate, manifest['as_of_date']);
      expect(
        jsonEncode(snap.links),
        jsonEncode(load('data/agency_links.json')['links']),
      );
      expect(snap.index.length, index.length);
      expect(jsonEncode(snap.index), jsonEncode(index));
      expect(jsonEncode(snap.compact), jsonEncode(compact));
      expect(jsonEncode(snap.forward), jsonEncode(legacy['forward']));
      expect(jsonEncode(snap.multi), jsonEncode(legacy['multi']));
      expect(
        jsonEncode(snap.institutions),
        jsonEncode(load('data/agency_institutions.json')['institutions']),
      );
    },
  );
}
