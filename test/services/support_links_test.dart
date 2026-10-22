import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/support_links.dart';

void main() {
  const repoIssues = '/Fentanest/safetyreport-mobile/issues/new';

  test('버그 제보 링크는 모바일 레포의 bug_report.yml 양식을 칸 id 로 채워 연다', () {
    final uri = SupportLinks.bugReport(
      appVersion: '2.5.1',
      buildNumber: '180',
      modeLabel: 'Standalone',
      osLabel: 'Android 15',
      deviceModel: 'SM-S911N',
    );
    expect(uri.scheme, 'https');
    expect(uri.host, 'github.com');
    expect(uri.path, repoIssues);
    expect(uri.queryParameters, {
      'template': 'bug_report.yml',
      'title': '[버그] ',
      'platform': 'Android',
      'os-version': 'Android 15',
      'device-model': 'SM-S911N',
      'app-version': '2.5.1 (빌드 180)',
      'mode': 'Standalone 모드',
    });
  });

  test('모드 표기는 양식 드롭다운 보기 글자로 바뀐다', () {
    expect(SupportLinks.formMode('Client'), 'Client 모드');
    expect(SupportLinks.formMode('Standalone'), 'Standalone 모드');
    expect(SupportLinks.formMode('Standalone (데모)'), '데모');
    expect(SupportLinks.formMode('뭔가 다른 값'), isNull);
    expect(SupportLinks.formPlatform('Android 14'), 'Android');
    expect(SupportLinks.formPlatform('iOS 18'), 'iOS');
    expect(SupportLinks.formPlatform('linux'), isNull);
  });

  test('모르는 값은 쿼리에 넣지 않는다(빈 칸, 기기 모델 포함)', () {
    final q = SupportLinks.bugReport(
      appVersion: '',
      buildNumber: '',
      modeLabel: '??',
      osLabel: 'linux',
    ).queryParameters;
    expect(q.keys.toSet(), {'template', 'title', 'os-version'});
    expect(q['os-version'], 'linux');
  });

  test('빌드 번호만 없으면 버전만 적는다', () {
    final q = SupportLinks.bugReport(
      appVersion: '2.5.1',
      buildNumber: '',
      modeLabel: 'Client',
      osLabel: 'Android 15',
    ).queryParameters;
    expect(q['app-version'], '2.5.1');
    expect(q['mode'], 'Client 모드');
  });

  test('기능 제안 링크는 feature_request.yml 양식과 앱 버전 칸만 채운다', () {
    final uri = SupportLinks.featureRequest(
      appVersion: '2.5.1',
      buildNumber: '180',
      modeLabel: 'Client',
      osLabel: 'Android 14',
    );
    expect(uri.host, 'github.com');
    expect(uri.path, repoIssues);
    expect(uri.queryParameters, {
      'template': 'feature_request.yml',
      'title': '[기능 제안] ',
      'app-version': '2.5.1 (빌드 180)',
    });
  });

  test('공개 게시판 링크에 민감한 값이 들어가지 않는다: 허용된 칸 id 외에는 쿼리가 없다', () {
    const allowed = {
      'template',
      'title',
      'platform',
      'os-version',
      'device-model',
      'app-version',
      'mode',
    };
    final uris = [
      SupportLinks.bugReport(
        appVersion: '2.5.1',
        buildNumber: '1',
        modeLabel: 'Client',
        osLabel: 'Android 15',
        deviceModel: 'Pixel',
      ),
      SupportLinks.featureRequest(
        appVersion: '2.5.1',
        buildNumber: '1',
        modeLabel: 'Client',
        osLabel: 'Android 15',
      ),
    ];
    for (final u in uris) {
      expect(u.queryParameters.keys.toSet().difference(allowed), isEmpty);
      expect(u.queryParameters.containsKey('body'), isFalse);
      expect(u.userInfo, isEmpty);
    }
  });
}
