/// 설정 > 도움·문의 카드의 외부 링크.
///
/// 버그 제보는 GitHub 새 이슈 화면을 앱 버전·모드·OS 가 채워진 양식으로 연다.
/// 이슈는 공개되므로 아이디·API 키·서버 주소·차량번호 같은 값은 절대 자동으로 넣지 않는다.
class SupportLinks {
  static const _repo = 'https://github.com/Fentanest/safetyreport-mobile';
  static const issueList = '$_repo/issues';
  static const userGuide = 'https://hb.worklazy.net/mysafetyreport/';

  static String environmentBlock({
    required String appVersion,
    required String modeLabel,
    required String osLabel,
  }) =>
      '---\n'
      '앱 버전: ${appVersion.isEmpty ? '확인 안 됨' : 'v$appVersion'}\n'
      '모드: $modeLabel\n'
      'OS: $osLabel\n';

  static Uri bugReport({
    required String appVersion,
    required String modeLabel,
    required String osLabel,
  }) {
    final body =
        '> 공개 게시판입니다. 아이디·비밀번호·API 키·서버 주소·차량번호 같은 개인정보는 적지 마세요.\n\n'
        '### 어떤 문제가 있었나요?\n\n\n'
        '### 어떻게 하면 다시 생기나요? (순서대로)\n1. \n2. \n\n'
        '### 원래 기대한 동작\n\n\n'
        '### 화면에 나온 오류 메시지 (있다면)\n\n\n'
        '${environmentBlock(appVersion: appVersion, modeLabel: modeLabel, osLabel: osLabel)}';
    return Uri.parse(
      '$_repo/issues/new',
    ).replace(queryParameters: {'title': '[버그] ', 'body': body});
  }

  static Uri featureRequest({
    required String appVersion,
    required String modeLabel,
    required String osLabel,
  }) {
    final body =
        '> 공개 게시판입니다. 개인정보는 적지 마세요.\n\n'
        '### 어떤 기능이 있으면 좋을까요?\n\n\n'
        '### 어떤 상황에서 쓰고 싶나요?\n\n\n'
        '${environmentBlock(appVersion: appVersion, modeLabel: modeLabel, osLabel: osLabel)}';
    return Uri.parse(
      '$_repo/issues/new',
    ).replace(queryParameters: {'title': '[기능 요청] ', 'body': body});
  }
}
