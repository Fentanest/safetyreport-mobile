/// 금액 없는 과태료의 법정 최저 기준 추정 (docs/design/statistics-spec.md §4-1, §4-2).
///
/// - 추정값은 DB 에 저장하지 않고 입력(번호판, 신고 메뉴, 발생시각, 사진 촬영 시각)으로 매번 계산한다.
/// - 확정 과태료(`범칙금_과태료` 의 금액)와 섞지 않는다. 호출자는 별도 필드로만 내보낸다.
/// - 금액은 일반적으로 알려진 기본 금액(최저 기준)이다. 가중(고속도로, 감경 등)은 데이터로 알 수 없으면 반영하지 않는다.
/// - 모바일 Standalone 도 같은 규칙을 쓴다. 규칙을 바꾸면 RULE_VERSION 과 tests/fixtures/fine_estimate_vectors.json 을
///   양쪽 레포에서 함께 바꾼다.
/// - 대상 판정([isEstimateTarget])과 계산([estimate]/[estimateForReport])은 통계([local_statistics.dart]),
///   커뮤니티 payload([observation_rules.dart] `_fineEstimateField`), 신고 목록/상세 화면, 엑셀·CSV 내보내기가
///   모두 같은 함수를 호출한다 — 대상 판정 로직을 호출부마다 다시 만들지 않는다(row-estimate, 2026-10-12).

library;

import 'package:intl/intl.dart';
import '../models/report.dart';
import 'report_category.dart' as report_category;

const String ruleVersion = "2026-10-12.1";

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

/// 진짜 '소분류 없음'(메뉴만 있고 세부가 없음)일 때만 true.
///
/// 소분류 코드(SSNPC_TYPE)가 있으면(모르는 코드라도) 소분류가 있는데 못 알아본 것이므로 false —
/// EP-99 처럼 코드표에 없는 코드는 밤샘주차가 아니라 일반 주정차로 떨어져야 한다(Astra #7).
/// 대분류(SSNPC_CD)만 있고 소분류가 비면 소분류 없음이다(Astra 재검수 #6). 그때는 entry_value 의
/// '메뉴-소분류'에서 '-' 뒤가 비어 있는지로 판단한다.
bool _noSubcategoryInfo(report_category.Resolved resolved, dynamic entryValue) {
  // 소분류 코드가 있으면(모르는 코드라도) 못 알아본 소분류 — 대분류만 있으면 소분류 없음(Astra 재검수 #6).
  if (resolved.ssnpcType != null) return false;
  // 대분류가 IP(소화전·교차로 등 지정 구역)면 '기타 불법주정차'가 아니다 — 밤샘주차는 EP(일반)만(최종 감사 #3).
  if (resolved.ssnpcCd != null && resolved.ssnpcCd != 'EP') return false;
  final sub = _text(entryValue).split('-').skip(1).join('-');
  return sub.trim().isEmpty;
}

String? classify(Map<String, dynamic> record) {
  final category = _text(record["category"]);
  final entryValue = record["entry_value"];
  final resolved = report_category.resolve(
    record["ssnpc_cd"],
    record["ssnpc_type"],
    entryValue,
  );
  final code = resolved.code;
  final name = _text(record["신고명"]);
  final law = _text(record["위반법규"]);
  final plate = record["차량번호"];
  final first = record["사진_첫촬영"];
  final last = record["사진_끝촬영"];

  if (resolved.category == "parking" || category == "parking") {
    if (code == "EP-02" ||
        (code == null && _noSubcategoryInfo(resolved, entryValue))) {
      if (isCommercialTruck(plate) && isOvernightWindow(first, last)) {
        return "overnight_truck";
      }
      return "parking";
    }
    if (code == "EP-04") {
      return "ev_charging";
    }
    if (code == "EP-01") {
      return "disabled_parking";
    }
    if (code == "EP-03") {
      return "fire_lane";
    }
    if (code == "IP-01") {
      return "hydrant";
    }
    if (code == "IP-05") {
      final hour = _occurHour(record["발생시각"]);
      if (hour != null && hour >= 8 && hour < 20) {
        return "school_zone";
      }
      return "parking";
    }
    return "parking";
  }
  if (code == "DR-06" || code == "CM-05") {
    return "waste";
  }
  if ((resolved.category == "traffic" || category == "traffic") &&
      (code == "TV-05" ||
          (name.contains("버스") && name.contains("차로")) ||
          law.contains("제15조"))) {
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
  "fire_lane": _FineRule("소방기본법 시행령 별표3 제2호 아목(소방차 전용구역 주차·진입 방해, 1차)", {
    null: 500000,
  }),
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

/// 해당 유형·차종의 기본/2시간 가중 금액만 대조한다.
Set<int> legalFineAmounts(Map<String, dynamic>? record) {
  record ??= {};
  final rule = _rules[classify(record)];
  if (rule == null) return {};
  final cls = fineClass(record['차량번호']);
  return {
    for (final table in [rule.amounts, rule.surcharge ?? <String?, int>{}])
      if ((table[cls] ?? table[null]) != null) (table[cls] ?? table[null])!,
  };
}

const amountTokenPattern = r'[0-9,.]+';
final _amountToken = RegExp('($amountTokenPattern)\\s*원');

final _normalAmount = RegExp(r'^(?:[0-9]+|[0-9]{1,3}(?:[,.][0-9]{3})+)$');

/// 정상 숫자는 유지. 깨진 묶음은 구분자 제거/묶음 끝 0 보정 후보 중 법정 금액 하나만 선택.
int? parseAmountNumber(String number, [Iterable<int> legalAmounts = const []]) {
  if (_normalAmount.hasMatch(number)) {
    return int.tryParse(number.replaceAll(RegExp(r'[,.]'), ''));
  }
  if (!RegExp(r'^[0-9]+(?:[,.][0-9]+)+$').hasMatch(number)) return null;
  final parts = number.split(RegExp(r'[,.]'));
  final candidates = <int>{};
  final intact = int.tryParse(parts.join());
  if (intact != null) candidates.add(intact);
  final normalized = [parts.first];
  if (parts.first.length <= 3) {
    for (var part in parts.skip(1)) {
      if (part.length < 3) {
        part = part.padRight(3, '0');
      } else if (part.length > 3) {
        if (!RegExp(r'^0+$').hasMatch(part.substring(3))) break;
        part = part.substring(0, 3);
      }
      normalized.add(part);
    }
    if (normalized.length == parts.length) {
      final value = int.tryParse(normalized.join());
      if (value != null) candidates.add(value);
    }
  }
  final matches = candidates.intersection(legalAmounts.toSet());
  return matches.length == 1 ? matches.single : null;
}

/// 원문은 보존하고 읽는 단계에서만 보정한다.
int extractFineAmount(String text, [Map<String, dynamic>? record]) {
  if (!text.contains('과태료')) return 0;
  final m = _amountToken.firstMatch(text);
  if (m == null) return 0;
  return parseAmountNumber(
        m[1]!,
        _normalAmount.hasMatch(m[1]!) ? const [] : legalFineAmounts(record),
      ) ??
      0;
}

String? correctedFineText(String text, [Map<String, dynamic>? record]) {
  if (!text.contains('과태료')) return null;
  final m = _amountToken.firstMatch(text);
  if (m == null || _normalAmount.hasMatch(m[1]!)) return null;
  final amount = parseAmountNumber(m[1]!, legalFineAmounts(record));
  if (amount == null) return null;
  final formatted = NumberFormat('#,###', 'en_US').format(amount);
  return text.replaceRange(m.start, m.start + m[1]!.length, formatted);
}

/// 과태료 원문(`범칙금_과태료`/`penalty_amount` 등)이 추정 대상인지 판정한다 — '과태료' 처분인데
/// 확정 금액을 읽지 못했을 때만 true. local_statistics.dart·observation_rules.dart(_fineEstimateField)·
/// 화면 표시·내보내기가 모두 이 함수를 쓴다(대상 판정 중복 구현 금지).
bool isEstimateTarget(String fineText, [Map<String, dynamic>? record]) {
  return fineText.contains('과태료') && extractFineAmount(fineText, record) == 0;
}

/// 같은 신고 맥락으로 대상 판정과 계산을 한 번에 수행한다.
/// 대상이 아니거나 분류 규칙이 없으면 null.
Map<String, dynamic>? estimateIfUnknown(
  String fineText,
  Map<String, dynamic> record,
) {
  if (!isEstimateTarget(fineText, record)) return null;
  return estimate(record);
}

/// 통계·업로드와 같은 판정 입력. 화면·내보내기는 이 변환을 함께 쓴다.
Map<String, dynamic> fineRecordForReport(Report report) => {
  "category": report.category,
  "entry_value": report.entryValue,
  "ssnpc_cd": report.ssnpcCd,
  "ssnpc_type": report.ssnpcType,
  "신고명": report.name,
  "위반법규": report.law,
  "차량번호": report.carNumber,
  "사진_첫촬영": report.photoFirstCapture,
  "사진_끝촬영": report.photoLastCapture,
  "발생시각": report.occurrenceTime,
};

/// [report] 변환과 대상 판정·계산을 함께 수행한다(화면·내보내기 공용).
Map<String, dynamic>? estimateForReport(Report report) =>
    estimateIfUnknown(report.fineInfo, fineRecordForReport(report));

/// 표시용 보정값. Report/DB 원문은 보존한다.
String fineTextForReport(Report report) =>
    correctedFineText(report.fineInfo, fineRecordForReport(report)) ??
    report.fineInfo;
