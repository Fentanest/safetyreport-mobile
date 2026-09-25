// 서버↔모바일 계산 동등성 하네스. 서버 레포 scripts/dev/logic_parity_check.py 가 환경변수로 호출한다.
// 가져온 모바일 DB 로 대시보드·통계·통계 요약을 설정 조합별로 계산해 JSON 으로 쓴다(서버가 같은 조합으로 계산해 비교).
// 환경변수가 없으면 건너뛴다(일반 flutter test 에는 영향 없음). 임시 폴더만 쓰고 끝나면 지운다(결정 D-8).
//   SR_LP_MOBILE_DB=<모바일 DB>  SR_LP_OUT=<결과 JSON 경로>
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final env = Platform.environment;
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'compute stats on an imported mobile db (parity harness)',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = Directory.systemTemp.createTempSync('sr_logic_parity_');
      await databaseFactory.setDatabasesPath(dir.path);
      SharedPreferences.setMockInitialValues({});
      File(
        env['SR_LP_MOBILE_DB']!,
      ).copySync('${dir.path}/standalone_reports.db');
      try {
        final out = <String, dynamic>{};
        for (final ew in [false, true]) {
          for (final rep in [false, true]) {
            final s = await LocalDbService.computeSummary(
              excludeWithdraw: ew,
              useRepresentativeRecords: rep,
            );
            out['summary|ew=$ew|rep=$rep'] = {
              'total': s.total,
              'acceptCount': s.acceptCount,
              'partialCount': s.partialCount,
              'rejectCount': s.rejectCount,
              'supplementCount': s.supplementCount,
              'processingCount': s.processingCount,
              'completedCount': s.completedCount,
              'withdrawCount': s.withdrawCount,
              'withdrawRawCount': s.withdrawRawCount,
              'tFineCount': s.tFineCount,
              'tPenaltyCount': s.tPenaltyCount,
              'tRejectCount': s.tRejectCount,
              'tUnconfirmedCount': s.tUnconfirmedCount,
            };
            for (final np in [false, true]) {
              out['stats|ew=$ew|rep=$rep|np=$np'] =
                  await LocalDbService.computeStats(
                    excludeWithdraw: ew,
                    useRepresentativeRecords: rep,
                    normalizePolice: np,
                  );
            }
            out['overview|ew=$ew|rep=$rep'] =
                await LocalDbService.computeStatsOverview(
                  excludeWithdraw: ew,
                  useRepresentativeRecords: rep,
                );
          }
        }
        // 서버가 이 데이터에서 고른 필터 조합(연도·법규) — 키 형식은 서버 스크립트와 같게
        final filters = (jsonDecode(env['SR_LP_FILTERS'] ?? '[]') as List)
            .cast<Map<String, dynamic>>();
        for (final f in filters) {
          final keys = f.keys.toList()..sort();
          final ftag = keys.map((k) => '$k=${f[k]}').join(',');
          for (final ew in [false, true]) {
            for (final rep in [false, true]) {
              final tag = 'ew=$ew|rep=$rep|f=$ftag';
              out['fstats|$tag'] = await LocalDbService.computeStats(
                year: f['year'] as String?,
                law: f['law'] as String?,
                excludeWithdraw: ew,
                useRepresentativeRecords: rep,
              );
              out['foverview|$tag'] = await LocalDbService.computeStatsOverview(
                year: f['year'] as String?,
                law: f['law'] as String?,
                excludeWithdraw: ew,
                useRepresentativeRecords: rep,
              );
            }
          }
        }
        File(env['SR_LP_OUT']!).writeAsStringSync(jsonEncode(out));
      } finally {
        await LocalDbService.closeDb();
        dir.deleteSync(recursive: true);
      }
    },
    skip: env['SR_LP_MOBILE_DB'] == null
        ? 'logic parity harness: SR_LP_MOBILE_DB 가 있을 때만 실행'
        : false,
  );
}
