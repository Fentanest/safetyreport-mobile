import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/agency_registry.dart';
import 'package:safetyreport/services/local_db_service.dart';

void injectIdentityRegistry() => AgencyRegistry.testInject(
  AgencyRegistrySnapshot(
    links: const [],
    index: const {},
    forward: const {},
    multi: const {'9999993': '옛기관'},
    institutions: const {},
    registryVersion: 'synthetic-identity',
    asOfDate: '2026-10-18',
  ),
);

Future<void> seedIdentityReports() async {
  injectIdentityRegistry();
  for (var i = 0; i < 202; i++) {
    await LocalDbService.upsertReport(
      Report.fromJson({
        'ID': i == 0 ? 'target' : (i == 201 ? 'old' : 'other-$i'),
        '신고번호': 'SYN-${i.toString().padLeft(4, '0')}',
        '신고명': i == 0 ? '정확한 대상 신고' : '다른 신고 $i',
        '신고일': '2026-10-01',
        '답변일': '2026-10-02',
        '처리상태': '수용',
        '상태': '답변완료',
        '처리기관코드': i == 0 ? '9999991' : (i == 201 ? '9999993' : '9999992'),
        '처리기관': i == 201 ? '옛기관' : '합성기관',
        '담당자': i == 0 ? '김민수' : (i == 201 ? '이담당' : '김민수(교통과)'),
        '위반법규': '합성 법규',
        'ssnpc_cd': 'TV',
        'ssnpc_type': '09',
      }),
      'traffic',
      '자동차·교통위반-기타 자동차 안전기준 위반',
    );
  }
}
