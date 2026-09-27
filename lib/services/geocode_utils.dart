/// DB 교환과 지도에 사용하는 좌표 파싱. 주소를 외부 서비스에 보내지 않는다.
double? parseGeoDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final parsed = value.toDouble();
    return parsed.isFinite ? parsed : null;
  }
  if (value is String) {
    if (value.trim().isEmpty) return null;
    final parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }
  return null;
}

String normalizeGeocodeAddress(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return '';
  return text.replaceAll(RegExp(r'\s+'), ' ');
}

Map<String, Object?> officialGeoPayload(
  String? address,
  Object? latitude,
  Object? longitude,
) {
  final normalized = normalizeGeocodeAddress(address);
  final lat = parseGeoDouble(latitude);
  final lng = parseGeoDouble(longitude);
  final located =
      lat != null &&
      lng != null &&
      lat >= 32 &&
      lat <= 39.5 &&
      lng >= 124 &&
      lng <= 132;
  return {
    '주소정규화': normalized,
    '행정구역': '',
    '위도': located ? lat : null,
    '경도': located ? lng : null,
    '지오코딩상태': located
        ? 'ok'
        : normalized.isEmpty
        ? ''
        : 'not_found',
  };
}
