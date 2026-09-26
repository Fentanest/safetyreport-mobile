// 커뮤니티 공유 DTO 규칙 (contracts/community-ingest/observation.md 2·3절).
//
// 순수 함수만 둔다. DB·파일·시계는 community_capture.dart 가 담당한다.
// PC `services/parser.py` → 어댑터 입력 키와 같은 의미다.
library;

/// 문자열 정리 clean(s, n): 제어문자·연속 공백 → 공백 하나, 앞뒤 제거, 코드포인트 n자.
String? cleanString(Object? value, int n) {
  if (value is! String) return null;
  final out = StringBuffer();
  var pendingSpace = false;
  for (final rune in value.runes) {
    final isWs = _isWhitespace(rune) || _isControl(rune);
    if (isWs) {
      pendingSpace = true;
      continue;
    }
    if (pendingSpace && out.isNotEmpty) out.write(' ');
    pendingSpace = false;
    out.writeCharCode(rune);
  }
  var s = out.toString();
  if (s.isEmpty) return null;
  final runes = s.runes.toList(growable: false);
  if (runes.length > n) s = String.fromCharCodes(runes.sublist(0, n));
  return s.isEmpty ? null : s;
}

bool _isControl(int rune) =>
    (rune >= 0x00 && rune <= 0x1F) || rune == 0x7F;

bool _isWhitespace(int rune) {
  if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0B ||
      rune == 0x0C || rune == 0x0D) {
    return true;
  }
  return rune == 0x85 ||
      rune == 0xA0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000;
}

/// 처리상태 → 공유 status. 표에 없으면 other.
String mapStatus(String? cleaned) {
  switch (cleaned) {
    case '수용':
      return 'accepted';
    case '일부수용':
      return 'partial';
    case '불수용':
      return 'rejected';
    case '답변완료':
    case '기타':
      return 'completed_unknown';
    case '취하':
      return 'withdrawn';
    case '이송':
      return 'transferred';
    case '보완요청':
      return 'supplement';
    case '처리중':
      return 'processing';
    default:
      return 'other';
  }
}

/// eligible = status ∈ {accepted, partial, rejected, completed_unknown}.
bool isEligibleStatus(String status) =>
    status == 'accepted' ||
    status == 'partial' ||
    status == 'rejected' ||
    status == 'completed_unknown';

/// entry_value → category (PC category_from_entry_value 와 같음).
String categoryOf(String? entryValue) {
  final v = entryValue ?? '';
  if (v.contains('자동차·교통위반')) return 'traffic';
  if (v.contains('불법주정차신고')) return 'parking';
  return 'other';
}

/// 날짜 day(s): 앞 10자 YYYY-MM-DD 그대로, YYYY.MM.DD → 하이픈,
/// 8자리 YYYYMMDD → 하이픈 삽입. 실제 달력 날짜가 아니면 null.
String? parseDay(Object? value) {
  if (value == null) return null;
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  String? cand;
  var m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (m != null) {
    cand = '${m[1]}-${m[2]}-${m[3]}';
  } else if ((m = RegExp(r'^(\d{4})\.(\d{2})\.(\d{2})').firstMatch(s)) !=
      null) {
    cand = '${m![1]}-${m[2]}-${m[3]}';
  } else if ((m = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(s)) != null) {
    cand = '${m![1]}-${m[2]}-${m[3]}';
  } else {
    return null;
  }
  return _isValidDate(cand) ? cand : null;
}

bool _isValidDate(String cand) {
  final y = int.parse(cand.substring(0, 4));
  final m = int.parse(cand.substring(5, 7));
  final d = int.parse(cand.substring(8, 10));
  if (m < 1 || m > 12 || d < 1) return false;
  const dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  var max = dim[m - 1];
  if (m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))) max = 29;
  return d <= max;
}

/// 금액 확정 규칙. (kind, confirmedWon) — kind 는 문법 불일치여도 앞머리로 판정.
({String kind, int? confirmedWon}) parseAmount(Object? value) {
  final raw = value is String ? value.trim() : '';
  final hasPenalty = raw.contains('범칙금');
  final hasFine = raw.contains('과태료');
  final String kind;
  if (hasPenalty && hasFine) {
    kind = 'combined';
  } else if (raw.startsWith('범칙금')) {
    kind = 'penalty';
  } else if (raw.startsWith('과태료')) {
    kind = 'fine';
  } else {
    kind = 'unknown';
  }
  if (kind == 'unknown') return (kind: kind, confirmedWon: null);
  final m =
      RegExp(r'^(과태료|범칙금):\s*([0-9][0-9.,]*)\s*원$').firstMatch(raw);
  if (m == null) return (kind: kind, confirmedWon: null);
  final num = m[2]!;
  final parts = num.split(RegExp(r'[,.]'));
  if (parts.length == 1) {
    if (!RegExp(r'^[0-9]+$').hasMatch(num)) {
      return (kind: kind, confirmedWon: null);
    }
  } else {
    if (parts.first.isEmpty || parts.first.length > 3) {
      return (kind: kind, confirmedWon: null);
    }
    for (var i = 1; i < parts.length; i++) {
      if (parts[i].length != 3 || !RegExp(r'^[0-9]{3}$').hasMatch(parts[i])) {
        return (kind: kind, confirmedWon: null);
      }
    }
  }
  final won = int.tryParse(parts.join());
  if (won == null || won > 100000000) {
    return (kind: kind, confirmedWon: null);
  }
  return (kind: kind, confirmedWon: won);
}

/// `^벌점:\s*([0-9]{1,4})\s*점$`, ≤1000.
int? parsePenaltyPoints(Object? value) {
  final raw = value is String ? value.trim() : '';
  final m = RegExp(r'^벌점:\s*([0-9]{1,4})\s*점$').firstMatch(raw);
  if (m == null) return null;
  final v = int.parse(m[1]!);
  return v <= 1000 ? v : null;
}

/// 처분 구분. rejected → none, 아니면 금액 앞머리·경고.
String dispositionOf(String status, Object? penaltyAmount) {
  if (status == 'rejected') return 'none';
  final raw = penaltyAmount is String ? penaltyAmount.trim() : '';
  if (raw.startsWith('범칙금')) return 'penalty';
  if (raw.startsWith('과태료')) return 'fine';
  if (raw.startsWith('경고')) return 'warning';
  return 'unknown';
}

/// double 의 최단 왕복 10진 문자열 (지수 표기 없음, 소수점 없으면 .0).
String formatDouble(double v) {
  var s = v.toString();
  if (s.contains('e') || s.contains('E')) s = _expandExponent(s);
  if (!s.contains('.')) s = '$s.0';
  return s;
}

String _expandExponent(String s) {
  var neg = false;
  if (s.startsWith('-')) {
    neg = true;
    s = s.substring(1);
  }
  final parts = s.split(RegExp('[eE]'));
  final exp = int.parse(parts[1]);
  final mantissa = parts[0].split('.');
  final intPart = mantissa[0];
  final fracPart = mantissa.length > 1 ? mantissa[1] : '';
  final digits = '$intPart$fracPart';
  final pointPos = intPart.length + exp;
  String out;
  if (pointPos <= 0) {
    out = '0.${'0' * (-pointPos)}$digits';
  } else if (pointPos >= digits.length) {
    out = '$digits${'0' * (pointPos - digits.length)}';
  } else {
    out = '${digits.substring(0, pointPos)}.${digits.substring(pointPos)}';
  }
  out = out.replaceAll(RegExp(r'(\.\d*?)0+$'), r'$1');
  out = out.replaceAll(RegExp(r'\.$'), '');
  return neg ? '-$out' : out;
}

double? parseGeoDouble(Object? value) {
  if (value == null) return null;
  if (value is num) {
    final v = value.toDouble();
    return v.isFinite ? v : null;
  }
  if (value is String) {
    if (value.trim().isEmpty) return null;
    final v = double.tryParse(value.trim());
    if (v == null || !v.isFinite) return null;
    return v;
  }
  return null;
}

/// observation.md 3절 — 어댑터 입력 → 공유 payload (순수 함수).
///
/// 어댑터 입력 키: processing_status, penalty_amount, report_date, response_date,
/// processing_agency, person_in_charge, car_number, violation_location,
/// entry_value, penalty_points, geocode{status, lat, lng}.
Map<String, Object?> buildPayload(Map<String, Object?> input) {
  final statusRaw = cleanString(input['processing_status'], 40);
  final status = mapStatus(statusRaw);
  final eligible = isEligibleStatus(status);
  final amount = parseAmount(input['penalty_amount']);
  final reportDate = parseDay(input['report_date']);
  final responseDay = parseDay(input['response_date']);
  final completedDate = eligible ? responseDay : null;

  final geo = input['geocode'];
  double? lat;
  double? lng;
  var geoOk = false;
  if (geo is Map) {
    if ((geo['status']?.toString() ?? '') == 'ok') {
      lat = parseGeoDouble(geo['lat']);
      lng = parseGeoDouble(geo['lng']);
      geoOk = lat != null &&
          lng != null &&
          lat >= 32 &&
          lat <= 39.5 &&
          lng >= 124 &&
          lng <= 132;
    }
  }
  final location = geoOk
      ? <String, Object?>{
          'lat': formatDouble(lat!),
          'lng': formatDouble(lng!),
          'source': 'geocode',
        }
      : <String, Object?>{'lat': null, 'lng': null, 'source': 'none'};

  return <String, Object?>{
    'address': cleanString(input['violation_location'], 200),
    'agency_name': cleanString(input['processing_agency'], 200),
    'amount': <String, Object?>{
      'confirmed_won': amount.confirmedWon,
      'kind': amount.kind,
      'penalty_points': parsePenaltyPoints(input['penalty_points']),
    },
    'category': categoryOf(input['entry_value']?.toString()),
    'completed_date': completedDate,
    'disposition': dispositionOf(status, input['penalty_amount']),
    'location': location,
    'manager_name': cleanString(input['person_in_charge'], 160),
    'report_date': reportDate,
    'status': status,
    'status_raw': statusRaw,
    'vehicle_raw': cleanString(input['car_number'], 64),
  };
}

/// payload 가 eligible 인지 (amount.status 기준이 아니라 status 기준).
bool payloadEligible(Map<String, Object?> payload) =>
    isEligibleStatus(payload['status']?.toString() ?? 'other');
