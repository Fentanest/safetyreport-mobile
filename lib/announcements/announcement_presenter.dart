// 앱 공지 가져오기·표시(CLIENT-RULES 9절). 카카오 로그인 없이 공개 키(apikey)만 쓴다.
//
// - 요청: GET {url}/functions/v1/app-announcements?app=mobile&mode=..&platform=..&version=.. (쿼리 정확히 4개)
// - 6시간에 한 번만 가져온다(마지막 시도 시각 저장). 실패(네트워크·4xx·5xx·형식 이상)면 아무것도 띄우지 않고 다음 때를 기다린다.
// - 한 번에 팝업 하나, 닫으면 다음 것. "보지 않기" 는 SharedPreferences `app_announcement_snooze.<id>`(만료 epoch ms),
//   "닫기" 는 이번 실행 동안만(메모리).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../community/report/report_env.dart';
import '../widgets/announcement_popup.dart';
import 'announcement_model.dart';

class AnnouncementPresenter {
  AnnouncementPresenter._();

  static const fetchInterval = Duration(hours: 6);
  static const timeout = Duration(seconds: 10);
  static const maxResponseBytes = 64 * 1024;
  static const prefsAttempt = 'app_announcement_attempt';
  static const prefsCache = 'app_announcement_cache';
  static String snoozeKey(String id) => 'app_announcement_snooze.$id';
  static const modes = {'standalone', 'client', 'demo'};

  /// 이번 실행에서 "닫기" 한 공지 id.
  static final Set<String> _dismissed = {};
  static bool _busy = false;

  @visibleForTesting
  static Future<bool> Function(Uri uri) launcher = (uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @visibleForTesting
  static void resetForTest() {
    _dismissed.clear();
    _busy = false;
    launcher = (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 메인 화면 진입 때 부른다. 아무것도 던지지 않는다. 이미 표시 중이면 바로 돌아온다.
  ///
  /// [openModeSwitch] 는 설정의 모드 변경 흐름(`_confirmModeReset`)을 여는 콜백(B 가 연결).
  static Future<void> maybeShow(
    BuildContext context, {
    required String mode,
    required Future<void> Function() openModeSwitch,
  }) async {
    if (_busy || !modes.contains(mode)) return;
    _busy = true;
    try {
      final candidates = await _candidates(mode);
      for (final a in candidates) {
        if (!context.mounted) return;
        if (_dismissed.contains(a.id)) continue;
        if (await _snoozed(a.id)) continue;
        if (!context.mounted) return;
        final choice = await showDialog<AnnouncementChoice>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AnnouncementPopup(announcement: a),
        );
        switch (choice) {
          case AnnouncementChoice.snooze:
            await _snooze(a);
          case AnnouncementChoice.primary:
            _dismissed.add(a.id);
            await _runAction(a.action, openModeSwitch);
            return; // 사용자가 다른 화면으로 갔다. 다음 공지는 다음 기회에.
          case AnnouncementChoice.close:
          case null:
            _dismissed.add(a.id);
        }
      }
    } catch (_) {
      // 공지는 다른 기능에 영향을 주지 않는다.
    } finally {
      _busy = false;
    }
  }

  static Future<void> _runAction(
    AnnouncementAction? action,
    Future<void> Function() openModeSwitch,
  ) async {
    if (action == null) return;
    switch (action.kind) {
      case AnnouncementActionKind.appAction:
        if (action.appAction == 'open_mode_switch') await openModeSwitch();
      case AnnouncementActionKind.url:
        final url = action.url;
        // 표시 직전에 한 번 더 허용 목록을 확인한다.
        if (url != null && AnnouncementParser.linkAllowed(url)) {
          await launcher(Uri.parse(url));
        }
    }
  }

  // ── 숨김 ─────────────────────────────────────────────────────

  static Future<bool> _snoozed(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(snoozeKey(id));
    if (until == null) return false;
    if (ReportEnv.now().millisecondsSinceEpoch < until) return true;
    await prefs.remove(snoozeKey(id)); // 지난 만료 값은 읽을 때 지운다.
    return false;
  }

  static Future<void> _snooze(AppAnnouncement a) async {
    if (a.snoozeDays <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final until = ReportEnv.now().add(Duration(hours: 24 * a.snoozeDays));
    await prefs.setInt(snoozeKey(a.id), until.millisecondsSinceEpoch);
  }

  // ── 가져오기 ─────────────────────────────────────────────────

  /// 보일 후보. 6시간이 안 지났으면 마지막 정상 응답(캐시)을 다시 검사해서 쓰고, 지났으면 새로 가져온다.
  static Future<List<AppAnnouncement>> _candidates(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final now = ReportEnv.now();
    final last = prefs.getInt(prefsAttempt);
    final due =
        last == null ||
        now.millisecondsSinceEpoch - last >= fetchInterval.inMilliseconds ||
        now.millisecondsSinceEpoch < last; // 시계가 뒤로 갔으면 다시 가져온다.
    if (!due) return _fromCache(prefs, mode);

    // 실패해도 다음 시도는 6시간 뒤(재시도 반복 없음).
    await prefs.setInt(prefsAttempt, now.millisecondsSinceEpoch);
    await prefs.remove(prefsCache);
    final fetched = await _fetch(mode);
    if (fetched == null) return const [];
    await prefs.setString(
      prefsCache,
      jsonEncode({
        'mode': mode,
        'items': [for (final a in fetched) a.toWire()],
      }),
    );
    return fetched;
  }

  static List<AppAnnouncement> _fromCache(
    SharedPreferences prefs,
    String mode,
  ) {
    try {
      final raw = prefs.getString(prefsCache);
      if (raw == null) return const [];
      final d = jsonDecode(raw);
      if (d is! Map || d['mode'] != mode || d['items'] is! List) {
        return const [];
      }
      return [for (final e in d['items'] as List) ?AnnouncementParser.item(e)];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<AppAnnouncement>?> _fetch(String mode) async {
    final cfg = ReportEnv.config;
    if (!cfg.isConfigured) return null;
    final version = await ReportEnv.appVersion();
    if (version == null) return null;
    final uri = Uri.parse('${cfg.supabaseUrl}/functions/v1/app-announcements')
        .replace(
          queryParameters: {
            'app': 'mobile',
            'mode': mode,
            'platform': ReportEnv.platform(),
            'version': version,
          },
        );
    final client = ReportEnv.newClient();
    try {
      final res = await client
          .get(uri, headers: {'apikey': cfg.publishableKey})
          .timeout(timeout);
      if (res.statusCode != 200 || res.bodyBytes.length > maxResponseBytes) {
        return null;
      }
      return AnnouncementParser.response(
        jsonDecode(utf8.decode(res.bodyBytes)),
      );
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    } catch (_) {
      return null;
    }
  }
}
