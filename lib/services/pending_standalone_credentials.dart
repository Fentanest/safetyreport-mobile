/// 새 설치에서 Standalone 로그인 화면에 처음 입력한 안전신문고 자격을, 커뮤니티 게이트(카카오·동의)와
/// 권한 안내를 지나 실제 로그인을 실행할 때까지 **메모리에만** 들고 있는다.
///
/// 디스크·SharedPreferences·보안 저장소에는 절대 쓰지 않는다(실제 저장은 로그인 성공 뒤 기존 경로가 한다).
/// 프로세스가 죽으면 사라지고, 그때는 사용자가 로그인 화면을 한 번 다시 보게 된다(허용).
class PendingStandaloneCredentials {
  String? _username;
  String? _password;
  String? _phone;

  String get username => _username ?? '';
  String get password => _password ?? '';

  /// 사용자가 입력한 그대로의 휴대폰번호(하이픈 포함 가능).
  String get phone => _phone ?? '';

  bool get isEmpty => _username == null;

  void set({
    required String username,
    required String password,
    required String phone,
  }) {
    _username = username;
    _password = password;
    _phone = phone;
  }

  void clear() {
    _username = null;
    _password = null;
    _phone = null;
  }
}
