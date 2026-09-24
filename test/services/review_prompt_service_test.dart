import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/models/report.dart';
import 'package:safetyreport/services/app_prefs_keys.dart';
import 'package:safetyreport/services/review_prompt_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeReviewApi implements ReviewApi {
  int requests = 0;
  bool available = true;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> requestReview() async => requests++;

  @override
  Future<void> openStoreListing() async {}
}

final _now = DateTime(2026, 9, 24, 12);

Report _report({
  String status = '수용',
  String fine = '',
  Duration answeredAgo = const Duration(hours: 5),
  DateTime? syncedAt,
}) => Report(
  id: '1',
  reportNumber: 'SPP-2609-0000001',
  name: '신고',
  date: '2026-09-01',
  responseDate: '2026-09-24',
  agency: '기관',
  manager: '담당',
  status: status,
  result: status,
  fineInfo: fine,
  penaltyPoints: '',
  carNumber: '',
  law: '',
  location: '',
  occurrenceDate: '',
  occurrenceTime: '',
  reportContent: '',
  processContent: '',
  syncedAt: (syncedAt ?? _now.subtract(answeredAgo)).millisecondsSinceEpoch,
);

void main() {
  late _FakeReviewApi api;

  /// 설치 30일, 사용한 날 10일인 사용자.
  void seasoned([Map<String, Object> extra = const {}]) {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.reviewFirstOpenAt: _now
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch,
      AppPrefsKeys.reviewActiveDays: 10,
      ...extra,
    });
  }

  setUp(() {
    api = _FakeReviewApi();
    ReviewPromptService.api = api;
    ReviewPromptService.resetSession();
    seasoned();
  });

  Future<bool> ask(Report r, {bool isDemo = false, DateTime? at}) =>
      ReviewPromptService.maybeRequestAfterViewing(
        r,
        isDemo: isDemo,
        now: at ?? _now,
      );

  test('최근 받은 좋은 결과(수용·과태료)를 본 뒤에 요청한다', () async {
    expect(await ask(_report()), isTrue);
    expect(api.requests, 1);

    seasoned();
    expect(await ask(_report(status: '답변완료', fine: '과태료: 40,000원')), isTrue);
  });

  test('불수용·처리중이거나 오래된 답변이면 요청하지 않는다', () async {
    expect(await ask(_report(status: '불수용')), isFalse);
    expect(await ask(_report(status: '처리중')), isFalse);
    expect(await ask(_report(answeredAgo: const Duration(days: 4))), isFalse);
    expect(api.requests, 0);
  });

  test('설치 7일 미만·사용한 날 5일 미만·데모·이번 실행 오류면 요청하지 않는다', () async {
    SharedPreferences.setMockInitialValues({
      AppPrefsKeys.reviewFirstOpenAt: _now
          .subtract(const Duration(days: 3))
          .millisecondsSinceEpoch,
      AppPrefsKeys.reviewActiveDays: 10,
    });
    expect(await ask(_report()), isFalse);

    seasoned({AppPrefsKeys.reviewActiveDays: 4});
    expect(await ask(_report()), isFalse);

    seasoned();
    expect(await ask(_report(), isDemo: true), isFalse);

    ReviewPromptService.markSessionError();
    expect(await ask(_report()), isFalse);
    expect(api.requests, 0);
  });

  test('90일에 한 번, 평생 3번까지만 요청한다', () async {
    expect(await ask(_report()), isTrue);
    expect(
      await ask(_report(), at: _now.add(const Duration(days: 30))),
      isFalse,
    );

    var t = _now;
    for (var i = 0; i < 3; i++) {
      t = t.add(const Duration(days: 91));
      final asked = await ask(_report(syncedAt: t), at: t);
      expect(asked, i < 2, reason: '${i + 2}번째 요청');
    }
    expect(api.requests, 3);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(AppPrefsKeys.reviewRequestCount), 3);
  });

  test('사용한 날은 하루에 한 번만 센다', () async {
    SharedPreferences.setMockInitialValues({});
    await ReviewPromptService.recordAppOpen(now: _now);
    await ReviewPromptService.recordAppOpen(
      now: _now.add(const Duration(hours: 3)),
    );
    await ReviewPromptService.recordAppOpen(
      now: _now.add(const Duration(days: 1)),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(AppPrefsKeys.reviewActiveDays), 2);
    expect(
      prefs.getInt(AppPrefsKeys.reviewFirstOpenAt),
      _now.millisecondsSinceEpoch,
    );
  });
}
