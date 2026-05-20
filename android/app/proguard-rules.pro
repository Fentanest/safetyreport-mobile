# Android 15+ 에서 deprecated 된 system bar color API 는 앱에서 사용하지 않는다.
# Flutter embedding / 라이브러리 쪽 정적 참조가 Play Console 권장사항을 유발해
# release 최적화 단계에서 관련 호출만 제거한다.
-assumenosideeffects class android.view.Window {
    public void setStatusBarColor(int);
    public void setNavigationBarColor(int);
    public void setNavigationBarDividerColor(int);
}
