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

Map<String, Object?> buildPendingGeoPayload(
  String? address, {
  String status = 'pending',
}) {
  final normalized = normalizeGeocodeAddress(address);
  final resolvedStatus = normalized.isEmpty ? '' : status;
  return {
    '주소정규화': normalized,
    '행정구역': '',
    '위도': null,
    '경도': null,
    '지오코딩상태': resolvedStatus,
  };
}

Map<String, Object?> extractGeoPayload(
  Map<String, dynamic>? source, {
  String fallbackAddress = '',
}) {
  final row = source ?? const <String, dynamic>{};
  final addressCandidate =
      row['주소정규화']?.toString() ??
      (fallbackAddress.isNotEmpty ? fallbackAddress : row['위반장소']?.toString());
  final normalized = normalizeGeocodeAddress(addressCandidate);
  final lat = parseGeoDouble(row['위도']);
  final lng = parseGeoDouble(row['경도']);
  var status = row['지오코딩상태']?.toString().trim() ?? '';
  if (status.isEmpty && lat != null && lng != null) {
    status = 'ok';
  }
  return {
    '주소정규화': normalized,
    '행정구역': row['행정구역']?.toString().trim() ?? '',
    '위도': lat,
    '경도': lng,
    '지오코딩상태': status,
  };
}

Map<String, Object?> prepareGeoPayloadForAddress(
  String? address, {
  Map<String, dynamic>? existingRecord,
}) {
  final normalized = normalizeGeocodeAddress(address);
  if (normalized.isEmpty) {
    return buildPendingGeoPayload('', status: '');
  }

  final existingPayload = extractGeoPayload(
    existingRecord,
    fallbackAddress: normalized,
  );
  final existingAddress = normalizeGeocodeAddress(
    existingRecord?['주소정규화']?.toString() ?? existingRecord?['위반장소']?.toString(),
  );
  final sameAddress =
      existingAddress.isNotEmpty && existingAddress == normalized;
  final status = existingPayload['지오코딩상태']?.toString() ?? '';
  final lat = existingPayload['위도'];
  final lng = existingPayload['경도'];

  if (sameAddress &&
      (status == 'ok' ||
          status == 'not_found' ||
          (lat != null && lng != null))) {
    return existingPayload;
  }
  return buildPendingGeoPayload(normalized, status: 'pending');
}
