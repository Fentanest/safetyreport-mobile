part of 'local_db_service.dart';

class _AgencyAgg {
  final String name;
  final String person;
  final String agencyKey;
  int total = 0, fines = 0, warn = 0, reject = 0, unconfirmed = 0;

  /// S-10: 완료도 취하도 아닌 상태(처리중·진행·검토중·보완요청·이송·빈 값 등). 미분류와 따로 센다.
  int inProgress = 0;

  int dispositionUnknown = 0;
  int noPenalty = 0;
  int unclassified = 0;

  int totalFine = 0;
  int fineAmountUnknown = 0; // S-05: 과태료인데 금액을 읽지 못한 건(0원과 구분)
  int estimatedFineAmount = 0;
  int estimatedFineCount = 0;

  int responseDaySum = 0, responseDayCount = 0;
  int ratingSum = 0, ratingCount = 0;

  _AgencyAgg(this.name, this.person, [this.agencyKey = '']);

  void add(Map<String, dynamic> r) {
    final weight = (r['_weight'] as int?) ?? 1;
    total += weight;
    final fine = (r['범칙금_과태료'] as String? ?? '');
    final completed = ReportPolicy.isCompleted(r['처리상태']);
    // 통계표 8분류: 서버 `_stats_row_disposition_counts` 와 같은 규칙(ReportPolicy.tableDisposition, contracts/report-policy-vectors.json).
    final d = ReportPolicy.tableDisposition(r);
    if (d['fines']!) fines += weight;
    if (d['warnings']!) warn += weight;
    if (d['rejects']!) reject += weight;
    if (d['in_progress']!) inProgress += weight;
    if (d['unconfirmed']!) unconfirmed += weight;
    if (d['disposition_unknown']!) dispositionUnknown += weight;
    if (d['no_penalty']!) noPenalty += weight;
    if (d['unclassified']!) unclassified += weight;
    final fineAmount = extractFineAmount(fine);
    totalFine += fineAmount * weight;
    if (fine.contains('과태료') && fineAmount == 0) {
      fineAmountUnknown += weight;
      final est = fine_estimate.estimate(r);
      if (est != null) {
        estimatedFineAmount += (est['amount'] as int) * weight;
        estimatedFineCount += weight;
      }
    }

    final date = r['신고일'] as String? ?? '';
    final resp = r['답변일'] as String? ?? '';
    // S-10: 처리기간은 완료 신고만(이송 답변일이 붙은 처리중·취하 제외).
    if (completed && date.length >= 10 && resp.length >= 10) {
      try {
        final d = LocalDbService._parseOverviewDate(date);
        final rd = LocalDbService._parseOverviewDate(resp);
        final days = d == null || rd == null ? -1 : rd.difference(d).inDays;
        // S-01: 서버와 같이 날짜가 뒤바뀐(음수) 건은 평균에서 제외.
        if (days >= 0) {
          responseDaySum += days * weight;
          responseDayCount += weight;
        }
      } catch (_) {}
    }

    final rating = (r['별점'] as num?)?.toInt();
    if (rating != null && rating >= 1 && rating <= 5) {
      ratingSum += rating * weight;
      ratingCount += weight;
    }
  }

  Map<String, dynamic> toJson() {
    final t = total > 0 ? total.toDouble() : 1.0;
    final avgRating = ratingCount == 0
        ? null
        : double.parse((ratingSum / ratingCount).toStringAsFixed(2));
    return {
      'agency': name,
      'agency_key': agencyKey,
      'person': person,
      'total': total,
      'fines': fines,
      'fines_pct': double.parse((fines / t * 100).toStringAsFixed(1)),
      'warnings': warn,
      'warnings_pct': double.parse((warn / t * 100).toStringAsFixed(1)),
      'rejects': reject,
      'rejects_pct': double.parse((reject / t * 100).toStringAsFixed(1)),
      'unconfirmed': unconfirmed,
      'unconfirmed_pct': double.parse(
        (unconfirmed / t * 100).toStringAsFixed(1),
      ),
      'disposition_unknown': dispositionUnknown,
      'disposition_unknown_pct': double.parse(
        (dispositionUnknown / t * 100).toStringAsFixed(1),
      ),
      'no_penalty': noPenalty,
      'no_penalty_pct': double.parse((noPenalty / t * 100).toStringAsFixed(1)),
      'unclassified': unclassified,
      'unclassified_pct': double.parse(
        (unclassified / t * 100).toStringAsFixed(1),
      ),
      'in_progress': inProgress,
      'in_progress_pct': double.parse(
        (inProgress / t * 100).toStringAsFixed(1),
      ),
      'total_fine_amount': totalFine,
      'fine_amount_unknown': fineAmountUnknown,
      'estimated_fine_amount': estimatedFineAmount,
      'estimated_fine_count': estimatedFineCount,
      'avg_rating': avgRating,
      'rating_count': ratingCount,
      // 2026-09-28: 평균 처리기간 표본 수(서버 `avg_days_count`). 표 합계가 행 평균을 이 수로 가중한다.
      'avg_days_count': responseDayCount,
      // S-01: 서버 _calc_avg_days 와 같이 소수 1자리.
      'avg_days': responseDayCount == 0
          ? null
          : double.parse(
              (responseDaySum / responseDayCount).toStringAsFixed(1),
            ),
    };
  }
}

/// Incremental table aggregation: memory grows with institutions/persons, never reports.
class _StatsCategoryAccumulator {
  final agencies = <String, _AgencyAgg>{};
  final persons = <String, _AgencyAgg>{};
  final laws = <String>{};
  bool emptyLaw = false;
  int fine = 0, estimated = 0, estimatedCount = 0;

  void addLaw(Map<String, dynamic> r) {
    final law = r['위반법규']?.toString() ?? '';
    if (law.isEmpty) {
      emptyLaw = true;
    } else {
      laws.add(law);
    }
  }

  void add(Map<String, dynamic> r) {
    final weight = (r['_weight'] as int?) ?? 1;
    final amount = extractFineAmount(r['범칙금_과태료']?.toString() ?? '');
    fine += amount * weight;
    if ((r['범칙금_과태료']?.toString() ?? '').contains('과태료') && amount == 0) {
      final est = fine_estimate.estimate(r);
      if (est != null) {
        estimated += (est['amount'] as int) * weight;
        estimatedCount += weight;
      }
    }
    if (!LocalDbService._overviewCompletedStatuses.contains(
      (r['처리상태']?.toString() ?? '').trim(),
    )) {
      return;
    }
    final keyed = registryKeyedAgency(r['처리기관코드'], r['처리기관']?.toString() ?? '');
    if (keyed.display.isEmpty) return;
    agencies
        .putIfAbsent(keyed.key, () => _AgencyAgg(keyed.display, '', keyed.key))
        .add(r);
    final person = (r['담당자']?.toString() ?? '').trim();
    if (LocalDbService._unassignedPersonValues.contains(person)) return;
    persons
        .putIfAbsent(
          '${keyed.key}\t$person',
          () => _AgencyAgg(keyed.display, person, keyed.key),
        )
        .add(r);
  }

  Map<String, dynamic> toJson() {
    List<Map<String, dynamic>> sorted(Iterable<_AgencyAgg> aggs) =>
        aggs.map((a) => a.toJson()).toList()..sort((a, b) {
          var c = (b['total'] as int).compareTo(a['total'] as int);
          if (c == 0) {
            c = (a['agency'] as String).compareTo(b['agency'] as String);
          }
          if (c == 0) {
            c = (a['person'] as String).compareTo(b['person'] as String);
          }
          if (c == 0) {
            c = (a['agency_key'] as String).compareTo(
              b['agency_key'] as String,
            );
          }
          return c;
        });
    final byAgency = sorted(agencies.values), byPerson = sorted(persons.values);
    bool police(Map<String, dynamic> r) =>
        (r['agency'] as String).contains('경찰');
    return {
      'by_agency': byAgency,
      'by_person': byPerson,
      'police_by_agency': byAgency.where(police).toList(),
      'police_by_person': byPerson.where(police).toList(),
      'other_by_agency': byAgency.where((r) => !police(r)).toList(),
      'other_by_person': byPerson.where((r) => !police(r)).toList(),
      'available_laws': laws.toList()..sort(),
      'has_empty_law': emptyLaw,
      'total_fine_amount': fine,
      'estimated_fine_amount': estimated,
      'estimated_fine_count': estimatedCount,
    };
  }
}

/// Merge exact counts and sums; round once after the final page.
class _OverviewAccumulator {
  final counts = <String, int>{};
  final series = <String, Map<String, int>>{};
  final types = <String, int>{};
  final lawCounts = <String, int>{};
  final resultDistribution = <String, int>{};
  final disposition = <String, int>{};
  final fine = <String, int>{};

  void add(List<Map<String, dynamic>> rows) {
    final json = LocalDbService.summarizeOverviewRows(
      rows,
      includeInternal: true,
    );
    for (final e in json.entries) {
      if (e.value is int) {
        counts[e.key] = (counts[e.key] ?? 0) + (e.value as int);
      }
      if (e.key.startsWith('monthly_')) {
        final target = series.putIfAbsent(e.key, () => {});
        for (final row in e.value as List) {
          final month = row['month'] as String;
          target[month] = (target[month] ?? 0) + (row['count'] as int);
        }
      }
    }
    for (final row in json['report_types'] as List) {
      final name = row['name'] as String;
      types[name] = (types[name] ?? 0) + (row['count'] as int);
    }
    for (final row in json['violation_laws'] as List) {
      final name = row['name'] as String;
      lawCounts[name] = (lawCounts[name] ?? 0) + (row['count'] as int);
    }
    for (final pair in [
      ('disposition', disposition),
      ('fine_amount', fine),
      ('result_distribution', resultDistribution),
    ]) {
      for (final e in (json[pair.$1] as Map<String, dynamic>).entries) {
        pair.$2[e.key] = (pair.$2[e.key] ?? 0) + (e.value as int);
      }
    }
  }

  Map<String, dynamic> toJson() {
    // Add an empty page to provide all zero-valued fields even for 0 reports.
    if (counts.isEmpty) add(const []);
    final typeRows = types.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final n = counts['avg_days_count'] ?? 0;
    return {
      for (final e in counts.entries)
        if (e.key != '_day_sum') e.key: e.value,
      'avg_days': n == 0
          ? null
          : double.parse(((counts['_day_sum'] ?? 0) / n).toStringAsFixed(1)),
      for (final e in series.entries)
        e.key: [
          for (final month in e.value.keys.toList()..sort())
            {'month': month, 'count': e.value[month]},
        ],
      'disposition': disposition,
      'fine_amount': fine,
      'result_distribution': resultDistribution,
      'violation_laws': [
        for (final e
            in lawCounts.entries.toList()..sort((a, b) {
              final c = b.value.compareTo(a.value);
              return c != 0 ? c : a.key.compareTo(b.key);
            }))
          {
            'name': e.key,
            'filter': e.key.isEmpty ? '__없음__' : e.key,
            'count': e.value,
          },
      ],
      'report_types': [
        for (final e in typeRows) {'name': e.key, 'count': e.value},
      ],
    };
  }
}

class _MapCellAccumulator {
  int total = 0;
  double latSum = 0, lngSum = 0;
  String address = '';
  bool multipleAddresses = false;
  final statuses = <String, int>{},
      dispositions = <String, int>{},
      categories = <String, int>{},
      agencies = <String, int>{};
  final agencyNames = <String, String>{};
  void add(Map<String, dynamic> r) {
    final n = r['_weight'] as int;
    if ((r['addresses'] as int? ?? 0) > 1 ||
        r['min_lat'] != r['max_lat'] ||
        r['min_lng'] != r['max_lng']) {
      multipleAddresses = true;
    }
    total += n;
    latSum += (r['lat'] as num).toDouble() * n;
    lngSum += (r['lng'] as num).toDouble() * n;
    final text = (r['address']?.toString() ?? '').trim();
    if (address.isEmpty) {
      address = text;
    } else if (address != text) {
      multipleAddresses = true;
    }
    void count(Map<String, int> target, String label) =>
        target[label] = (target[label] ?? 0) + n;
    final label = ReportPolicy.breakdownStatus(r['처리상태']);
    if (const {
      '수용',
      '일부수용',
      '불수용',
      '기타',
      '답변완료',
      '보완요청',
      '처리중',
      '취하',
      '이송',
    }.contains(label)) {
      count(statuses, label);
    }
    // 4분류(ReportPolicy.dashboardDisposition): 처리중은 '미확인'에 둔다(서버 지도와 같음).
    final disposition = ReportPolicy.dashboardDisposition(r);
    if (disposition['fines']!) count(dispositions, '과태료');
    if (disposition['warnings']!) count(dispositions, '경고/범칙금');
    if (disposition['rejects']!) count(dispositions, '불수용/기타');
    if (disposition['unconfirmed']!) count(dispositions, '미확인');
    count(categories, switch (r['category']) {
      'traffic' => '교통위반',
      'parking' => '주정차위반',
      'other' => '기타위반',
      _ => '',
    });
    final keyed = registryKeyedAgency(r['처리기관코드'], r['처리기관']?.toString() ?? '');
    if (keyed.display.isNotEmpty) {
      count(agencies, keyed.key);
      agencyNames[keyed.key] = keyed.display;
    }
  }

  Map<String, dynamic> toJson() {
    List<Map<String, dynamic>> series(Map<String, int> source) => [
      for (final e in source.entries)
        if (e.key.isNotEmpty)
          {
            'label': e.key,
            'count': e.value,
            'pct': double.parse((e.value / total * 100).toStringAsFixed(1)),
          },
    ];
    return {
      'lat': latSum / total,
      'lng': lngSum / total,
      'total': total,
      'cluster': multipleAddresses,
      'address': multipleAddresses ? '지도 구역 집계 · 확대하여 주소 확인' : address,
      'region': '',
      'status_breakdown': series(statuses),
      'disposition_breakdown': series(dispositions),
      'category_breakdown': series(categories),
      'agency_breakdown': [
        for (final e in agencies.entries)
          {
            'agency_key': e.key,
            'name': agencyNames[e.key],
            'count': e.value,
            'pct': double.parse((e.value / total * 100).toStringAsFixed(1)),
          },
      ],
    };
  }
}
