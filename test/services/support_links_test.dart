import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/support_links.dart';

void main() {
  test('버그 제보 링크는 GitHub 새 이슈 양식에 버전·빌드 번호·모드·OS 만 채운다', () {
    final uri = SupportLinks.bugReport(
      appVersion: '1.2.3',
      buildNumber: '172',
      modeLabel: 'Standalone',
      osLabel: 'Android 15',
    );
    expect(uri.host, 'github.com');
    expect(uri.path, '/Fentanest/safetyreport-mobile/issues/new');
    expect(uri.queryParameters['title'], '[버그] ');
    final body = uri.queryParameters['body']!;
    expect(body, contains('앱 버전: v1.2.3\n빌드 번호: 172\n'));
    expect(body, contains('모드: Standalone'));
    expect(body, contains('OS: Android 15'));
    expect(body, contains('개인정보는 적지 마세요'));
  });

  test('버전·빌드 번호를 못 읽으면 "확인 안 됨"으로 적는다', () {
    final body = SupportLinks.featureRequest(
      appVersion: '',
      buildNumber: '',
      modeLabel: 'Client',
      osLabel: 'Android 14',
    ).queryParameters['body']!;
    expect(body, contains('앱 버전: 확인 안 됨\n빌드 번호: 확인 안 됨\n'));
    expect(body, contains('모드: Client'));
  });

  test('기능 요청 링크에도 앱 버전 바로 다음에 빌드 번호를 적는다', () {
    final body = SupportLinks.featureRequest(
      appVersion: '1.2.3',
      buildNumber: '173',
      modeLabel: 'Client',
      osLabel: 'Android 14',
    ).queryParameters['body']!;
    expect(body, contains('앱 버전: v1.2.3\n빌드 번호: 173\n'));
  });

  test('버그 제보에서 빌드 번호만 없으면 버전은 유지한다', () {
    final body = SupportLinks.bugReport(
      appVersion: '1.2.3',
      buildNumber: '',
      modeLabel: 'Standalone',
      osLabel: 'Android 15',
    ).queryParameters['body']!;
    expect(body, contains('앱 버전: v1.2.3\n빌드 번호: 확인 안 됨\n'));
  });
}
