import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/theme/app_theme.dart';

/// 리뉴얼 위젯 테스트 공용 하네스 (docs/testing/ui-test-plan.md §5).
const uiTextScales = [1.0, 1.3, 2.0];

/// [child] 를 앱 테마로 감싸 논리 [width]x[height] 에서 렌더하고, 렌더 중 난 예외(overflow 포함)를 돌려준다.
Future<List<FlutterErrorDetails>> pumpThemed(
  WidgetTester tester,
  Widget child, {
  required Brightness brightness,
  double textScale = 1.0,
  double width = 360,
  double height = 800,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, height),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(12),
              children: [child],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

String describeErrors(List<FlutterErrorDetails> errors) =>
    errors.map((e) => e.exceptionAsString().split('\n').first).join(' | ');

/// 긴 한글 신고명·기관명·비정상적으로 긴 차량번호·보완요청이 모두 들어간 fixture.
Report longFieldReport({String status = '처리중'}) => Report(
  id: 'fixture-long',
  reportNumber: 'SPP-2609-2206517',
  name: '어린이보호구역 중앙선 침범 역주행 및 신호위반 후 보행자 보호의무 불이행으로 인한 위험 상황 발생 신고',
  date: '2026-09-22',
  responseDate: '',
  agency: '경기도남부경찰청 부천원미경찰서 교통안전과 교통범죄수사팀 (지역경찰 합동 단속반)',
  manager: '',
  status: status,
  result: '',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '서울31바5845서울31바5845서울31바5845',
  law: '',
  location: '경기도 부천시 원미구 길주로 000 (중동, 아주 긴 건물명 상가 앞 교차로)',
  occurrenceDate: '2026-09-21',
  occurrenceTime: '08:10',
  reportContent: '',
  processContent: '',
  supplementCount: 2,
  supplementRequester: '부천원미경찰서 교통안전과 홍길동 (031-000-0000)',
);

/// 결측 필드 fixture (처리상태·차량번호·기관 없음).
Report missingFieldReport() => Report(
  id: 'fixture-missing',
  reportNumber: '',
  name: '',
  date: '',
  responseDate: '',
  agency: '',
  manager: '',
  status: '',
  result: '',
  fineInfo: '',
  penaltyPoints: '',
  carNumber: '',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
);

/// 골든용 폰트. 호스트에 없으면 null 을 돌려 골든 테스트를 건너뛴다(재현성: 같은 호스트·같은 폰트에서만 비교).
const _koreanFontPath =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';

Future<String?> loadGoldenFonts() async {
  final korean = File(_koreanFontPath);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final icons = flutterRoot == null
      ? null
      : File(
          '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
  if (!korean.existsSync()) return 'missing $_koreanFontPath';
  if (icons == null || !icons.existsSync()) {
    return 'missing MaterialIcons-Regular.otf (FLUTTER_ROOT)';
  }
  final ko = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.sublistView(korean.readAsBytesSync())));
  await ko.load();
  final mi = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
  await mi.load();
  return null;
}
