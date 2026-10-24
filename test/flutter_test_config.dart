import 'dart:async';

import 'package:safetyreport/services/standalone_api_service.dart';

/// 모든 시험 공통: 공식 사이트 요청 간격·429 기다림(실제 초 단위)을 건너뛴다.
/// 기다린 시간은 시험이 [StandaloneApiService.sleepForTest] 를 바꿔 직접 확인한다.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  StandaloneApiService.sleepForTest = (_) async {};
  await testMain();
}
