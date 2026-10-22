import 'package:flutter/foundation.dart';

import '../../models/app_mode.dart';

/// 첫 실행(설정 전)에 화면에서 고른 모드(CLIENT-RULES 7절, 2-5 첫 실행 모드 버그).
///
/// prefs `appMode` 는 설정을 끝내야 저장된다. 그 전에 게이트·온보딩이 기본값(Client)으로 판정하면
/// Standalone 을 고른 사용자도 동의가 `mobile_client` 로 붙었다. 설정 전에는 이 값을 게이트의 모드로 쓰고,
/// 아직 고르지 않았으면(null) 게이트는 동의 단계로 가지 않는다('unselected').
class FirstRunMode {
  FirstRunMode._();

  static final ValueNotifier<AppMode?> choice = ValueNotifier(null);

  /// 게이트 모드 문자열: 데모 → 'demo', 설정을 마쳤으면 저장된 모드, 아니면 고른 모드 또는 'unselected'.
  static String gateMode({
    required bool demo,
    required bool configured,
    required AppMode savedMode,
  }) {
    if (demo) return 'demo';
    if (configured) return savedMode.name;
    final chosen = choice.value;
    return chosen == null ? 'unselected' : chosen.name;
  }
}
