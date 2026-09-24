/// 금액 없는 과태료의 법정 최저 기준 추정 (docs/design/statistics-spec.md §4-1, §4-2).
///
/// - 추정값은 DB 에 저장하지 않고 입력(번호판, 신고 메뉴, 발생시각, 사진 촬영 시각)으로 매번 계산한다.
/// - 확정 과태료(`범칙금_과태료` 의 금액)와 섞지 않는다. 호출자는 별도 필드로만 내보낸다.
/// - 금액은 일반적으로 알려진 기본 금액(최저 기준)이다. 가중(고속도로, 감경 등)은 데이터로 알 수 없으면 반영하지 않는다.
/// - 모바일 Standalone 도 같은 규칙을 쓴다. 규칙을 바꾸면 RULE_VERSION 과 tests/fixtures/fine_estimate_vectors.json 을
///   양쪽 레포에서 함께 바꾼다.

library;

import 'package:intl/intl.dart';

const String ruleVersion = "2026-09-24.1";

const String _passenger = "승용등";
const String _van = "승합등";
const String _motorcycle = "이륜등";

final RegExp _plateRe = RegExp(r"^(?:[가-힣]{2,})?(\d{2,3})([가-힣])(\d{4})$");
final RegExp _motorcycleRe = RegExp(r"^(?:[가-힣]{2,})?\d?[가-힣]\d?\d{4}$");
const Set<String> _commercialTruckSymbols = {'바', '사', '아', '자', '배'};

String _normalizePlate(dynamic plate) {
  return (plate?.toString() ?? "").replaceAll(RegExp(r"\s+"), "");
}

String? vehicleKind(dynamic plate) {
  final text = _normalizePlate(plate);
  final match = _plateRe.firstMatch(text);
  if (match != null) {
    final digits = match.group(1)!;
    final number = int.tryParse(digits) ?? 0;
    if (digits.length == 2) {
      if (number >= 1 && number <= 69) return "승용";
      if (number >= 70 && number <= 79) return "승합";
      if (number >= 80 && number <= 97) return "화물";
      if (number >= 98 && number <= 99) return "특수";
      return null;
    }
    if (number >= 100 && number <= 699) return "승용";
    if (number >= 700 && number <= 799) return "승합";
    if (number >= 800 && number <= 979) return "화물";
    if (number >= 980 && number <= 997) return "특수";
    if (number >= 998 && number <= 999) return "긴급";
    return null;
  }
  if (_motorcycleRe.hasMatch(text)) {
    return "이륜";
  }
  return null;
}

String fineClass(dynamic plate) {
  final kind = vehicleKind(plate);
  if (kind == "승합" || kind == "특수") {
    return _van;
  }
  if (kind == "이륜") {
    return _motorcycle;
  }
  return _passenger;
}

bool isCommercialTruck(dynamic plate) {
  final text = _normalizePlate(plate);
  final match = _plateRe.firstMatch(text);
  return match != null &&
      vehicleKind(text) == "화물" &&
      _commercialTruckSymbols.contains(match.group(2));
}

String _text(dynamic value) {
  if (value == null) return "";
  return value.toString().trim();
}

DateTime? _parseTime(dynamic value) {
  final text = _text(value);
  if (text.isEmpty) return null;

  for (final fmtStr in [
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd HH:mm",
    "yyyy:MM:dd HH:mm:ss",
  ]) {
    try {
      final takeLen = fmtStr.contains("ss") ? 19 : 16;
      if (text.length >= takeLen) {
        final parsed = DateFormat(
          fmtStr,
        ).parseStrict(text.substring(0, takeLen));
        return parsed;
      }
    } catch (_) {}
  }
  return null;
}

double? photoSpanMinutes(dynamic first, dynamic last) {
  final start = _parseTime(first);
  final end = _parseTime(last);
  if (start == null || end == null) return null;
  return end.difference(start).inSeconds / 60.0;
}

bool isOvernightWindow(dynamic first, dynamic last) {
  final start = _parseTime(first);
  final end = _parseTime(last);
  if (start == null ||
      end == null ||
      start.year != end.year ||
      start.month != end.month ||
      start.day != end.day) {
    return false;
  }

  bool isWithinWindow(DateTime t) {
    return t.hour < 4 || (t.hour == 4 && t.minute == 0 && t.second == 0);
  }

  if (isWithinWindow(start) && isWithinWindow(end)) {
    return end.difference(start).inSeconds >= 3600;
  }
  return false;
}

int? _occurHour(dynamic occurTime) {
  final text = _text(occurTime);
  final match = RegExp(r"^\s*(\d{1,2}):(\d{2})").firstMatch(text);
  if (match != null) {
    return int.tryParse(match.group(1)!);
  }
  return null;
}

String? classify(Map<String, dynamic> record) {
  final category = _text(record["category"]);
  final entry = _text(record["entry_value"]);
  final name = _text(record["신고명"]);
  final law = _text(record["위반법규"]);
  final plate = record["차량번호"];
  final first = record["사진_첫촬영"];
  final last = record["사진_끝촬영"];

  if (entry.contains("불법주정차신고") || category == "parking") {
    if (isCommercialTruck(plate) && isOvernightWindow(first, last)) {
      return "overnight_truck";
    }
    if (entry.contains("충전")) {
      return "ev_charging";
    }
    if (entry.contains("장애인")) {
      return "disabled_parking";
    }
    if (entry.contains("소화전")) {
      return "hydrant";
    }
    if (entry.contains("어린이")) {
      final hour = _occurHour(record["발생시각"]);
      if (hour != null && hour >= 8 && hour < 20) {
        return "school_zone";
      }
      return "parking";
    }
    return "parking";
  }
  if (entry.contains("쓰레기, 폐기물")) {
    return "waste";
  }
  if (category == "traffic" &&
      ((name.contains("버스") && name.contains("차로")) || law.contains("제15조"))) {
    return "bus_lane";
  }
  return null;
}

class _FineRule {
  final String basis;
  final Map<String?, int> amounts;
  final Map<String?, int>? surcharge;

  const _FineRule(this.basis, this.amounts, [this.surcharge]);
}

const Map<String, _FineRule> _rules = {
  "bus_lane": _FineRule("도로교통법 시행령 별표6 제3호(일반도로 전용차로)", {
    _van: 60000,
    _passenger: 50000,
    _motorcycle: 40000,
  }),
  "parking": _FineRule(
    "도로교통법 시행령 별표6 제6호(주정차)",
    {_van: 50000, _passenger: 40000},
    {_van: 60000, _passenger: 50000},
  ),
  "hydrant": _FineRule(
    "도로교통법 시행령 별표6 제6호의2 나목(소화전, 표지 미확인)",
    {_van: 50000, _passenger: 40000},
    {_van: 60000, _passenger: 50000},
  ),
  "school_zone": _FineRule(
    "도로교통법 시행령 별표7 1(어린이보호구역 주정차, 08~20시)",
    {_van: 130000, _passenger: 120000},
    {_van: 140000, _passenger: 130000},
  ),
  "ev_charging": _FineRule("친환경자동차법 시행령 별표 제2호 가목(충전구역 주차)", {null: 100000}),
  "disabled_parking": _FineRule("장애인등편의법 제17조제4항(장애인전용주차구역)", {null: 100000}),
  "waste": _FineRule("폐기물관리법 시행령 별표8 1)가)(휴대 생활폐기물 투기)", {null: 50000}),
  "overnight_truck": _FineRule("화물자동차 운수사업법 시행규칙 별표3 제2호(밤샘주차, 개인 1.5톤 이하)", {
    null: 50000,
  }),
};

Map<String, dynamic>? estimate(Map<String, dynamic> record) {
  final ruleId = classify(record);
  if (ruleId == null) return null;

  final rule = _rules[ruleId]!;
  String basis = rule.basis;
  Map<String?, int> table = rule.amounts;
  final surcharge = rule.surcharge;

  final cls = fineClass(record["차량번호"]);
  final span = photoSpanMinutes(record["사진_첫촬영"], record["사진_끝촬영"]);

  if (surcharge != null && span != null && span >= 120) {
    table = surcharge;
    basis += " · 2시간 이상";
  }

  int? amount = table[cls] ?? table[null];
  if (amount == null) return null;

  final clsText = table.containsKey(null) ? '차종 무관' : cls;
  return {"amount": amount, "rule": ruleId, "basis": "$basis · $clsText"};
}
