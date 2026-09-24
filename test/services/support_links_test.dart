import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/support_links.dart';

void main() {
  test('버그 제보 링크는 GitHub 새 이슈 양식에 버전·모드·OS 만 채운다', () {
    final uri = SupportLinks.bugReport(
      appVersion: '1.2.3',
      modeLabel: 'Standalone',
      osLabel: 'Android 15',
    );
    expect(uri.host, 'github.com');
    expect(uri.path, '/Fentanest/safetyreport-mobile/issues/new');
    expect(uri.queryParameters['title'], '[버그] ');
    final body = uri.queryParameters['body']!;
    expect(body, contains('앱 버전: v1.2.3'));
    expect(body, contains('모드: Standalone'));
    expect(body, contains('OS: Android 15'));
    expect(body, contains('개인정보는 적지 마세요'));
  });

  test('버전을 못 읽으면 "확인 안 됨"으로 적는다', () {
    final body = SupportLinks.featureRequest(
      appVersion: '',
      modeLabel: 'Client',
      osLabel: 'Android 14',
    ).queryParameters['body']!;
    expect(body, contains('앱 버전: 확인 안 됨'));
    expect(body, contains('모드: Client'));
  });
}
