/// 설정 > 도움·문의 카드의 외부 링크.
///
/// 버그 제보·기능 제안은 모바일 레포의 새 이슈 양식(`.github/ISSUE_TEMPLATE/bug_report.yml`·`feature_request.yml`)을 연다.
/// 양식 칸 id(`platform`·`os-version`·`device-model`·`app-version`·`mode`)를 쿼리로 미리 채운다.
/// 이슈는 공개되므로 아이디·API 키·서버 주소·차량번호 같은 값은 절대 자동으로 넣지 않는다.
class SupportLinks {
  static const _repo = 'https://github.com/Fentanest/safetyreport-mobile';
  static const issueList = '$_repo/issues';

  /// PC·Android 사용 안내 글(제작자 블로그). 설정의 '사용 가이드'와 '홈페이지 바로가기'가 함께 쓴다.
  static const userGuide =
      'https://hb.worklazy.net/mysafetyreport-pc-android-guide/';

  /// 커뮤니티 지도(여러 사용자가 공유한 신고를 함께 보는 지도). 신고 지도 화면에서 연다.
  static const communityMap = 'https://safemap.worklazy.net/';

  static const _bugTemplate = 'bug_report.yml';
  static const _featureTemplate = 'feature_request.yml';

  /// 앱의 모드 표기를 버그 제보 양식 `mode` 드롭다운의 보기 글자로 바꾼다. 모르면 null(칸을 비워 둔다).
  static String? formMode(String modeLabel) {
    final m = modeLabel.trim();
    if (m.contains('데모')) return '데모';
    if (m.startsWith('Standalone')) return 'Standalone 모드';
    if (m.startsWith('Client')) return 'Client 모드';
    return null;
  }

  /// `os-version` 에 넣는 글자와 `platform` 드롭다운 값(Android·iOS). 모르면 platform 은 null.
  static String? formPlatform(String osLabel) {
    final o = osLabel.trim().toLowerCase();
    if (o.startsWith('android')) return 'Android';
    if (o.startsWith('ios')) return 'iOS';
    return null;
  }

  static String _versionField(String appVersion, String buildNumber) {
    if (appVersion.isEmpty) return '';
    return buildNumber.isEmpty ? appVersion : '$appVersion (빌드 $buildNumber)';
  }

  /// 새 이슈 양식을 연다(`template=` + 양식 칸 id 쿼리). 빈 값은 쿼리에 넣지 않는다.
  /// 공개 게시판이므로 아이디·서버 주소·차량번호·기기 식별자는 절대 넣지 않는다.
  /// `platform`·`mode` 는 드롭다운이라 보기 글자와 정확히 같을 때만 GitHub 이 채운다(다르면 GitHub 이 무시).
  static Uri bugReport({
    required String appVersion,
    required String buildNumber,
    required String modeLabel,
    required String osLabel,

    /// 기기 모델명(예: `Build.MODEL`). 모르면 빈 값 — 양식에서 직접 적는다.
    String deviceModel = '',
  }) {
    final platform = formPlatform(osLabel);
    final mode = formMode(modeLabel);
    final os = osLabel.trim();
    final model = deviceModel.trim();
    final version = _versionField(appVersion, buildNumber);
    return Uri.parse('$_repo/issues/new').replace(
      queryParameters: {
        'template': _bugTemplate,
        'title': '[버그] ',
        'platform': ?platform,
        if (os.isNotEmpty)
          'os-version': os.length > 80 ? os.substring(0, 80) : os,
        if (model.isNotEmpty) 'device-model': model,
        if (version.isNotEmpty) 'app-version': version,
        'mode': ?mode,
      },
    );
  }

  static Uri featureRequest({
    required String appVersion,
    required String buildNumber,
    required String modeLabel,
    required String osLabel,
  }) {
    final version = _versionField(appVersion, buildNumber);
    return Uri.parse('$_repo/issues/new').replace(
      queryParameters: {
        'template': _featureTemplate,
        'title': '[기능 제안] ',
        if (version.isNotEmpty) 'app-version': version,
      },
    );
  }
}
