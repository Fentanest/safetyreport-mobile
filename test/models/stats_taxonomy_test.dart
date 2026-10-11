import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/agency_stats.dart';
import 'package:safetyreport/models/stats_overview.dart';

// 5분류(스키마 6, 2026-10-11): 구서버(taxonomy=3) 응답에는 safety·living 키가 없다 — 모델은 그 둘을 null 로
// 두고(hasFiveCategories=false) other 로 안전신고·생활불편·기타를 모두 받는다. X-SR-Taxonomy: 5 로 받은
// 신서버 응답은 safety·living 섹션이 있고 hasFiveCategories=true. 서버 report_stats_service 와 같은 계약.
void main() {
  group('AgencyStats.fromJson', () {
    Map<String, dynamic> category({int total = 0}) => {
      'by_agency': [],
      'by_person': [],
      'police_by_agency': [],
      'police_by_person': [],
      'other_by_agency': [],
      'other_by_person': [],
      'available_laws': <String>[],
      'has_empty_law': false,
      'total_fine_amount': total,
    };

    test('구서버(3분류) 응답은 safety·living 이 null', () {
      final stats = AgencyStats.fromJson({
        'traffic': category(),
        'parking': category(),
        'other': category(total: 7),
        'available_years': ['2026'],
      });
      expect(stats.hasFiveCategories, isFalse);
      expect(stats.safety, isNull);
      expect(stats.living, isNull);
      expect(stats.other.totalFineAmount, 7);
      expect(stats.forCategory('safety').byAgency, isEmpty);
    });

    test('신서버(5분류) 응답은 safety·living 섹션을 그대로 파싱', () {
      final stats = AgencyStats.fromJson({
        'traffic': category(),
        'parking': category(),
        'safety': category(total: 3),
        'living': category(total: 5),
        'other': category(total: 1),
        'available_years': ['2026'],
      });
      expect(stats.hasFiveCategories, isTrue);
      expect(stats.safety!.totalFineAmount, 3);
      expect(stats.living!.totalFineAmount, 5);
      expect(stats.forCategory('safety').totalFineAmount, 3);
      expect(stats.forCategory('living').totalFineAmount, 5);
    });
  });

  group('StatsOverview.fromJson', () {
    Map<String, dynamic> summary({int total = 0}) => {
      'total': total,
      'completed': 0,
      'accept': 0,
      'partial': 0,
      'reject': 0,
      'supplement': 0,
      'processing': 0,
      'withdraw': 0,
      'avg_days': null,
      'avg_days_count': 0,
      'reversed_date_count': 0,
      'undated_report_count': 0,
      'monthly_reported': <Map<String, dynamic>>[],
      'monthly_answered': <Map<String, dynamic>>[],
    };

    test('구서버(3분류) 응답은 safety·living 이 null, other 가 예전처럼 합쳐진 값', () {
      final overview = StatsOverview.fromJson({
        'all': summary(total: 10),
        'traffic': summary(total: 4),
        'parking': summary(total: 2),
        'other': summary(total: 4),
        'year_basis': '답변일',
      });
      expect(overview.hasFiveCategories, isFalse);
      expect(overview.safety, isNull);
      expect(overview.living, isNull);
      expect(overview.other.total, 4);
      expect(overview.forCategory('safety').total, 0);
      expect(overview.forCategory('living').total, 0);
    });

    test('신서버(5분류) 응답은 safety·living 을 따로 파싱', () {
      final overview = StatsOverview.fromJson({
        'all': summary(total: 10),
        'traffic': summary(total: 4),
        'parking': summary(total: 2),
        'safety': summary(total: 1),
        'living': summary(total: 2),
        'other': summary(total: 1),
        'year_basis': '답변일',
      });
      expect(overview.hasFiveCategories, isTrue);
      expect(overview.safety!.total, 1);
      expect(overview.living!.total, 2);
      expect(overview.forCategory('safety').total, 1);
      expect(overview.forCategory('living').total, 2);
    });
  });
}
