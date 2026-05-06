import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/sunwi.dart';
import 'app_storage_paths.dart';

class SunwiDataset {
  final SunwiPayload payload;
  final List<Map<String, dynamic>> allRows;
  final List<Map<String, dynamic>> top5Rows;

  const SunwiDataset({
    required this.payload,
    required this.allRows,
    required this.top5Rows,
  });
}

class SunwiService {
  static const _baseUrl =
      'https://www.safetyreport.go.kr/api/v1/portal/introduction/safeSingoStatistics';
  static const _allCsvFileName = 'sunwi_category_all_latest.csv';
  static const _top5CsvFileName = 'sunwi_category_top5_latest.csv';
  static const _batchSize = 8;
  static const _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Referer': 'https://www.safetyreport.go.kr/',
    'Connection': 'close',
  };

  static final List<String> _targetCategories = [
    for (final group in _sunwiCategoryGroups)
      for (final child in (group['children'] as List<dynamic>))
        child.toString(),
  ];

  static final Map<String, String> _categoryLookup = {
    for (final group in _sunwiCategoryGroups)
      for (final child in (group['children'] as List<dynamic>))
        child.toString(): group['name'].toString(),
  };

  static Future<SunwiDataset> fetchStandalone({
    void Function(int completed, int total, String label)? onProgress,
  }) async {
    final targetYyyymm = _currentYyyymm();
    final allRows = <Map<String, dynamic>>[];
    final categoryRanking = {
      for (final category in _targetCategories)
        category: <Map<String, dynamic>>[],
    };
    final failed = <_SunwiRegionRequest>[];
    final queue = _buildRegionQueue();
    var completed = 0;

    final client = http.Client();
    try {
      for (var i = 0; i < queue.length; i += _batchSize) {
        final batch = queue.skip(i).take(_batchSize).toList();
        final responses = await Future.wait(
          batch.map((req) => _fetchRegion(client, req, targetYyyymm)),
        );
        for (final response in responses) {
          completed++;
          onProgress?.call(
            completed,
            queue.length,
            '${response.request.sido} ${response.request.sigungu}',
          );
          if (response.items == null) {
            failed.add(response.request);
            continue;
          }
          _appendRows(
            resultItems: response.items!,
            sidoName: response.request.sido,
            sigunguName: response.request.sigungu,
            allRows: allRows,
            categoryRanking: categoryRanking,
          );
        }
      }

      if (failed.isNotEmpty) {
        final retryTargets = List<_SunwiRegionRequest>.from(failed);
        failed.clear();
        for (var i = 0; i < retryTargets.length; i += _batchSize) {
          final batch = retryTargets.skip(i).take(_batchSize).toList();
          final label = batch.isNotEmpty
              ? '${batch.first.sido} ${batch.first.sigungu} 재시도'
              : '재시도';
          onProgress?.call(completed, queue.length, label);
          final responses = await Future.wait(
            batch.map((req) => _fetchRegion(client, req, targetYyyymm)),
          );
          for (final response in responses) {
            if (response.items == null) {
              failed.add(response.request);
              continue;
            }
            _appendRows(
              resultItems: response.items!,
              sidoName: response.request.sido,
              sigunguName: response.request.sigungu,
              allRows: allRows,
              categoryRanking: categoryRanking,
            );
          }
        }
      }
    } finally {
      client.close();
    }

    final builtTop5 = _buildTop5Rows(categoryRanking);
    final payload = SunwiPayload(
      available: builtTop5.$2.any((group) {
        return group.children.any((child) => child.items.isNotEmpty);
      }),
      period: targetYyyymm,
      periodLabel: _formatPeriodLabel(targetYyyymm),
      updatedAt: _formatTimestamp(DateTime.now()),
      categories: builtTop5.$2,
      error: '',
      failedCount: failed.length,
      csvDownloadUrl: '',
      allCsvDownloadUrl: '',
    );

    return SunwiDataset(
      payload: payload,
      allRows: allRows,
      top5Rows: builtTop5.$1,
    );
  }

  static Future<String> exportStandaloneCsv(
    SunwiDataset dataset, {
    required bool top5,
  }) async {
    final dir = await _standaloneExportDir();
    final fileName = top5 ? _top5CsvFileName : _allCsvFileName;
    final target = File('${dir.path}/$fileName');
    final rows = top5 ? dataset.top5Rows : dataset.allRows;
    final headers = top5
        ? const ['대분류', '소분류', '순위', '시도', '시군구', '건수']
        : const ['대분류', '소분류', '시도', '시군구', '건수'];
    final csv = _toCsv(headers, rows);
    await target.writeAsString(csv, encoding: utf8);
    return target.path;
  }

  static Future<Directory> _standaloneExportDir() async =>
      AppStoragePaths.subDir('sunwi');

  static List<_SunwiRegionRequest> _buildRegionQueue() {
    final queue = <_SunwiRegionRequest>[];
    _sunwiRegions.forEach((sidoName, info) {
      final data = info as Map<String, dynamic>;
      final sidoCode = data['sido']?.toString() ?? '';
      final sigungu = data['sigungu'] as Map<String, dynamic>? ?? const {};
      sigungu.forEach((sigunguName, sigunguCode) {
        queue.add(
          _SunwiRegionRequest(
            sido: sidoName,
            sidoCode: sidoCode,
            sigungu: sigunguName,
            sigunguCode: sigunguCode.toString(),
          ),
        );
      });
    });
    return queue;
  }

  static Future<_SunwiRegionResponse> _fetchRegion(
    http.Client client,
    _SunwiRegionRequest request,
    String targetYyyymm,
  ) async {
    try {
      final items = await _fetchStats(client, request, targetYyyymm);
      return _SunwiRegionResponse(request: request, items: items);
    } catch (_) {
      return _SunwiRegionResponse(request: request, items: null);
    }
  }

  static Future<List<dynamic>> _fetchStats(
    http.Client client,
    _SunwiRegionRequest request,
    String targetYyyymm,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 4; attempt++) {
      try {
        final response = await client
            .get(
              Uri.parse(_baseUrl).replace(
                queryParameters: {
                  'searchYesterday': '',
                  'seachDateType': 'A',
                  'C_FRM_YM': targetYyyymm,
                  'C_TO_YM': targetYyyymm,
                  'API_CTRD_CODE': request.sidoCode,
                  'API_SIGNGU_CODE': request.sigunguCode,
                },
              ),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        final decoded =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final result = decoded['result'];
        if (result is List) return result;
        return const [];
      } on TimeoutException catch (e) {
        lastError = e;
      } on SocketException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } on FormatException catch (e) {
        lastError = e;
      }
      if (attempt < 4) {
        await Future.delayed(Duration(seconds: attempt + 1));
      }
    }
    throw Exception(lastError);
  }

  static void _appendRows({
    required List<dynamic> resultItems,
    required String sidoName,
    required String sigunguName,
    required List<Map<String, dynamic>> allRows,
    required Map<String, List<Map<String, dynamic>>> categoryRanking,
  }) {
    final rowMap = <String, int>{};
    for (final item in resultItems.whereType<Map>()) {
      final normalized = item.cast<String, dynamic>();
      final name = _normalizeItemName(normalized);
      if (!_targetCategories.contains(name)) continue;
      rowMap[name] = _extractCount(normalized);
    }

    for (final category in _targetCategories) {
      final count = rowMap[category] ?? 0;
      final parent = _categoryLookup[category] ?? '';
      final regionRow = {'시도': sidoName, '시군구': sigunguName, '건수': count};
      categoryRanking[category]!.add(regionRow);
      allRows.add({
        '대분류': parent,
        '소분류': category,
        '시도': sidoName,
        '시군구': sigunguName,
        '건수': count,
      });
    }
  }

  static (List<Map<String, dynamic>>, List<SunwiParentCategory>) _buildTop5Rows(
    Map<String, List<Map<String, dynamic>>> categoryRanking,
  ) {
    final top5Rows = <Map<String, dynamic>>[];
    final categories = <SunwiParentCategory>[];

    for (final group in _sunwiCategoryGroups) {
      final parentName = group['name'].toString();
      final children = <SunwiChildCategory>[];
      for (final childName in (group['children'] as List<dynamic>)) {
        final childLabel = childName.toString();
        final rows =
            List<Map<String, dynamic>>.from(
              categoryRanking[childLabel] ?? const [],
            )..sort((a, b) {
              final left = (a['건수'] as num?)?.toInt() ?? 0;
              final right = (b['건수'] as num?)?.toInt() ?? 0;
              return right.compareTo(left);
            });
        final items = <SunwiItem>[];
        for (var i = 0; i < rows.length && i < 5; i++) {
          final row = rows[i];
          final rank = i + 1;
          final sido = row['시도']?.toString() ?? '';
          final sigungu = row['시군구']?.toString() ?? '';
          final count = (row['건수'] as num?)?.toInt() ?? 0;
          items.add(
            SunwiItem(
              rank: rank,
              sido: sido,
              sigungu: sigungu,
              count: count,
              region: '$sido $sigungu',
            ),
          );
          top5Rows.add({
            '대분류': parentName,
            '소분류': childLabel,
            '순위': rank,
            '시도': sido,
            '시군구': sigungu,
            '건수': count,
          });
        }
        children.add(
          SunwiChildCategory(
            name: childLabel,
            fullName: '$parentName > $childLabel',
            items: items,
          ),
        );
      }
      categories.add(SunwiParentCategory(name: parentName, children: children));
    }

    return (top5Rows, categories);
  }

  static String _normalizeItemName(Map<String, dynamic> item) {
    for (final key in ['NM', 'NAME', 'SUB_NM', 'TITLE', 'CD_NM']) {
      final value = item[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    return '';
  }

  static int _extractCount(Map<String, dynamic> item) {
    final value = item['CNT'];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _currentYyyymm([DateTime? now]) {
    final dt = now ?? DateTime.now();
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    return '$year$month';
  }

  static String _formatPeriodLabel(String yyyymm) {
    if (yyyymm.length != 6) return yyyymm;
    return '${yyyymm.substring(0, 4)}-${yyyymm.substring(4, 6)}';
  }

  static String _formatTimestamp(DateTime dt) {
    final yyyy = dt.year.toString().padLeft(4, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$mi:$ss';
  }

  static String _toCsv(List<String> headers, List<Map<String, dynamic>> rows) {
    final buffer = StringBuffer('\uFEFF');
    buffer.writeln(headers.map(_escapeCsvCell).join(','));
    for (final row in rows) {
      buffer.writeln(
        headers
            .map((header) => _escapeCsvCell(row[header]?.toString() ?? ''))
            .join(','),
      );
    }
    return buffer.toString();
  }

  static String _escapeCsvCell(String value) {
    final normalized = value.replaceAll('"', '""');
    if (normalized.contains(',') ||
        normalized.contains('"') ||
        normalized.contains('\n')) {
      return '"$normalized"';
    }
    return normalized;
  }
}

class _SunwiRegionRequest {
  final String sido;
  final String sidoCode;
  final String sigungu;
  final String sigunguCode;

  const _SunwiRegionRequest({
    required this.sido,
    required this.sidoCode,
    required this.sigungu,
    required this.sigunguCode,
  });
}

class _SunwiRegionResponse {
  final _SunwiRegionRequest request;
  final List<dynamic>? items;

  const _SunwiRegionResponse({required this.request, required this.items});
}

const _sunwiCategoryGroups = [
  {
    "name": "불법주정차신고",
    "children": [
      "소화전",
      "교차로 모퉁이",
      "버스정류소",
      "횡단보도",
      "어린이보호구역",
      "인도",
      "장애인전용구역",
      "기타불법주정차",
      "소방차전용구역",
      "친환경차충전구역",
    ],
  },
  {
    "name": "자동차·교통위반",
    "children": [
      "자동차 안전신고",
      "교통위반(고속도로 포함)",
      "이륜차 위반",
      "(구)적재물 추락방지,중량·용량 위반",
      "버스전용차로 위반(고속도로제외)",
      "번호판 규정 위반",
      "불법등화, 반사판(지) 가림·손상",
      "불법 튜닝, 해체, 조작",
      "기타 자동차 안전기준 위반",
      "난폭/보복운전",
    ],
  },
];

const _sunwiRegions = {
  "서울특별시": {
    "sido": "6110000",
    "sigungu": {
      "종로구": "3000000",
      "중구": "3010000",
      "용산구": "3020000",
      "성동구": "3030000",
      "광진구": "3040000",
      "동대문구": "3050000",
      "중랑구": "3060000",
      "성북구": "3070000",
      "강북구": "3080000",
      "도봉구": "3090000",
      "노원구": "3100000",
      "은평구": "3110000",
      "서대문구": "3120000",
      "마포구": "3130000",
      "양천구": "3140000",
      "강서구": "3150000",
      "구로구": "3160000",
      "금천구": "3170000",
      "영등포구": "3180000",
      "동작구": "3190000",
      "관악구": "3200000",
      "서초구": "3210000",
      "강남구": "3220000",
      "송파구": "3230000",
      "강동구": "3240000",
    },
  },
  "부산광역시": {
    "sido": "6260000",
    "sigungu": {
      "중구": "3250000",
      "서구": "3260000",
      "동구": "3270000",
      "영도구": "3280000",
      "부산진구": "3290000",
      "동래구": "3300000",
      "남구": "3310000",
      "북구": "3320000",
      "해운대구": "3330000",
      "사하구": "3340000",
      "금정구": "3350000",
      "강서구": "3360000",
      "연제구": "3370000",
      "수영구": "3380000",
      "사상구": "3390000",
      "기장군": "3400000",
    },
  },
  "대구광역시": {
    "sido": "6270000",
    "sigungu": {
      "중구": "3410000",
      "동구": "3420000",
      "서구": "3430000",
      "남구": "3440000",
      "북구": "3450000",
      "수성구": "3460000",
      "달서구": "3470000",
      "달성군": "3480000",
      "군위군": "5141000",
    },
  },
  "인천광역시": {
    "sido": "6280000",
    "sigungu": {
      "중구": "3490000",
      "동구": "3500000",
      "미추홀구": "3510000",
      "연수구": "3520000",
      "남동구": "3530000",
      "부평구": "3540000",
      "계양구": "3550000",
      "서구": "3560000",
      "강화군": "3570000",
      "옹진군": "3580000",
    },
  },
  "광주광역시": {
    "sido": "6290000",
    "sigungu": {
      "동구": "3590000",
      "서구": "3600000",
      "남구": "3610000",
      "북구": "3620000",
      "광산구": "3630000",
    },
  },
  "대전광역시": {
    "sido": "6300000",
    "sigungu": {
      "동구": "3640000",
      "중구": "3650000",
      "서구": "3660000",
      "유성구": "3670000",
      "대덕구": "3680000",
    },
  },
  "울산광역시": {
    "sido": "6310000",
    "sigungu": {
      "중구": "3690000",
      "남구": "3700000",
      "동구": "3710000",
      "북구": "3720000",
      "울주군": "3730000",
    },
  },
  "경기도": {
    "sido": "6410000",
    "sigungu": {
      "수원시": "3740000",
      "성남시": "3780000",
      "의정부시": "3820000",
      "안양시": "3830000",
      "부천시": "3860000",
      "광명시": "3900000",
      "평택시": "3910000",
      "동두천시": "3920000",
      "안산시": "3930000",
      "고양시": "3940000",
      "과천시": "3970000",
      "구리시": "3980000",
      "남양주시": "3990000",
      "오산시": "4000000",
      "시흥시": "4010000",
      "군포시": "4020000",
      "의왕시": "4030000",
      "하남시": "4040000",
      "용인시": "4050000",
      "파주시": "4060000",
      "이천시": "4070000",
      "안성시": "4080000",
      "김포시": "4090000",
      "연천군": "4140000",
      "가평군": "4160000",
      "양평군": "4170000",
      "화성시": "5530000",
      "광주시": "5540000",
      "양주시": "5590000",
      "포천시": "5600000",
    },
  },
  "강원특별자치도": {
    "sido": "6530000",
    "sigungu": {
      "춘천시": "4181000",
      "원주시": "4191000",
      "강릉시": "4201000",
      "동해시": "4211000",
      "태백시": "4221000",
      "속초시": "4231000",
      "삼척시": "4241000",
      "홍천군": "4251000",
      "횡성군": "4261000",
      "영월군": "4271000",
      "평창군": "4281000",
      "정선군": "4291000",
      "철원군": "4301000",
      "화천군": "4311000",
      "양구군": "4321000",
      "인제군": "4331000",
      "고성군": "4341000",
      "양양군": "4351000",
    },
  },
  "충청북도": {
    "sido": "6430000",
    "sigungu": {
      "청주시": "5710000",
      "충주시": "4390000",
      "제천시": "4400000",
      "보은군": "4420000",
      "옥천군": "4430000",
      "영동군": "4440000",
      "진천군": "4450000",
      "괴산군": "4460000",
      "음성군": "4470000",
      "단양군": "4480000",
      "증평군": "5570000",
    },
  },
  "충청남도": {
    "sido": "6440000",
    "sigungu": {
      "천안시": "4490000",
      "공주시": "4500000",
      "보령시": "4510000",
      "아산시": "4520000",
      "서산시": "4530000",
      "논산시": "4540000",
      "금산군": "4550000",
      "부여군": "4570000",
      "서천군": "4580000",
      "청양군": "4590000",
      "홍성군": "4600000",
      "예산군": "4610000",
      "태안군": "4620000",
      "계룡시": "5580000",
      "당진시": "5680000",
    },
  },
  "전북특별자치도": {
    "sido": "6540000",
    "sigungu": {
      "전주시": "4641000",
      "군산시": "4671000",
      "익산시": "4681000",
      "정읍시": "4691000",
      "남원시": "4701000",
      "김제시": "4711000",
      "완주군": "4721000",
      "진안군": "4731000",
      "무주군": "4741000",
      "장수군": "4751000",
      "임실군": "4761000",
      "순창군": "4771000",
      "고창군": "4781000",
      "부안군": "4791000",
    },
  },
  "전라남도": {
    "sido": "6460000",
    "sigungu": {
      "목포시": "4800000",
      "여수시": "4810000",
      "순천시": "4820000",
      "나주시": "4830000",
      "광양시": "4840000",
      "담양군": "4850000",
      "곡성군": "4860000",
      "구례군": "4870000",
      "고흥군": "4880000",
      "보성군": "4890000",
      "화순군": "4900000",
      "장흥군": "4910000",
      "강진군": "4920000",
      "해남군": "4930000",
      "영암군": "4940000",
      "무안군": "4950000",
      "함평군": "4960000",
      "영광군": "4970000",
      "장성군": "4980000",
      "완도군": "4990000",
      "진도군": "5000000",
      "신안군": "5010000",
    },
  },
  "경상북도": {
    "sido": "6470000",
    "sigungu": {
      "포항시": "5020000",
      "경주시": "5050000",
      "김천시": "5060000",
      "안동시": "5070000",
      "구미시": "5080000",
      "영주시": "5090000",
      "영천시": "5100000",
      "상주시": "5110000",
      "문경시": "5120000",
      "경산시": "5130000",
      "의성군": "5150000",
      "청송군": "5160000",
      "영양군": "5170000",
      "영덕군": "5180000",
      "청도군": "5190000",
      "고령군": "5200000",
      "성주군": "5210000",
      "칠곡군": "5220000",
      "예천군": "5230000",
      "봉화군": "5240000",
      "울진군": "5250000",
      "울릉군": "5260000",
    },
  },
  "경상남도": {
    "sido": "6480000",
    "sigungu": {
      "창원시": "5670000",
      "진주시": "5310000",
      "통영시": "5330000",
      "사천시": "5340000",
      "김해시": "5350000",
      "밀양시": "5360000",
      "거제시": "5370000",
      "양산시": "5380000",
      "의령군": "5390000",
      "함안군": "5400000",
      "창녕군": "5410000",
      "고성군": "5420000",
      "남해군": "5430000",
      "하동군": "5440000",
      "산청군": "5450000",
      "함양군": "5460000",
      "거창군": "5470000",
      "합천군": "5480000",
    },
  },
  "제주특별자치도": {
    "sido": "6500000",
    "sigungu": {"제주시": "6510000", "서귀포시": "6520000"},
  },
  "세종특별자치시": {
    "sido": "5690000",
    "sigungu": {
      "조치원읍": "5690066",
      "연기면": "5690067",
      "연동면": "5690068",
      "부강면": "5690069",
      "금남면": "5690070",
      "장군면": "5690071",
      "연서면": "5690072",
      "전의면": "5690073",
      "전동면": "5690074",
      "소정면": "5690075",
      "한솔동": "5690076",
      "도담동": "5690123",
      "아름동": "5690145",
      "종촌동": "5690184",
      "고운동": "5690219",
      "보람동": "5690220",
      "새롬동": "5690232",
      "대평동": "5690243",
      "소담동": "5690244",
      "다정동": "5690325",
      "반곡동": "5690351",
      "해밀동": "5690352",
      "어진동": "5690425",
      "나성동": "5690426",
    },
  },
};
