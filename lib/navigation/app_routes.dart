import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/crawl_screen.dart';
import '../screens/file_browser_screen.dart';

/// 하단 탭에서 빠진 화면(동기화/크롤링, 파일)으로 가는 공용 경로 (D-06, 2026-09-24).
///
/// - 하단 탭: 0 대시보드, 1 신고내역, 2 신고관리, 3 통계, 4 알림 (기존 인덱스 유지)
/// - 네이티브 딥링크의 옛 인덱스 5(파일)·6(동기화/크롤링)은 여기서 화면을 연다.
class AppRoutes {
  AppRoutes._();

  static const crawlRouteName = '/crawl';
  static const filesRouteName = '/files';

  /// 동기화/크롤링 화면은 한 번에 하나만 뜬다. 런처 바로가기 명령을 이 키로 전달한다.
  static final GlobalKey<CrawlScreenState> crawlScreenKey =
      GlobalKey<CrawlScreenState>();

  /// 동기화/크롤링 화면이 스택에 있는지. push 직후(첫 build 전)에도 true 라서
  /// 같은 프레임에 두 번 호출돼도 화면이 겹쳐 쌓이지 않는다(GlobalKey 중복 방지).
  static bool _crawlOpen = false;

  /// 동기화/크롤링 화면을 연다. 이미 스택에 있으면 그 화면까지 되돌아간다.
  static void openCrawl(BuildContext context) {
    final nav = Navigator.of(context);
    if (_crawlOpen) {
      nav.popUntil(
        (route) => route.settings.name == crawlRouteName || route.isFirst,
      );
      return;
    }
    _crawlOpen = true;
    unawaited(
      nav
          .push(
            MaterialPageRoute(
              settings: const RouteSettings(name: crawlRouteName),
              builder: (_) => CrawlScreen(key: crawlScreenKey),
            ),
          )
          .whenComplete(() => _crawlOpen = false),
    );
  }

  /// 파일 화면(로컬 내보내기 / 서버 파일). 설정 > 데이터 관리에서 연다.
  static void openFiles(BuildContext context) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          settings: const RouteSettings(name: filesRouteName),
          builder: (_) => const FileBrowserScreen(),
        ),
      ),
    );
  }

  /// 런처 바로가기(quick_sync / quick_crawl): 화면을 연 뒤 명령을 전달한다.
  /// CrawlScreen 은 초기 로딩 중이면 명령을 대기열에 두었다가 실행한다.
  static Future<void> runQuickAction(
    BuildContext context,
    String eventType,
  ) async {
    openCrawl(context);
    for (var attempt = 0; attempt < 10; attempt++) {
      final state = crawlScreenKey.currentState;
      if (state != null) {
        await state.handleQuickAction(eventType);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}
