// 설정 단계 보고(CLIENT-RULES 4-2): POST {SUPABASE_URL}/functions/v1/community-account/setup-progress.
//
// 업로드 연결이 생기기 전(카카오 로그인 ~ 연결 등록)에 어디서 멈췄는지 서버가 알 수 있게 단계 코드만 보낸다.
// 공식 사이트 ID·비밀번호·서버 주소·API 키·기기 식별자는 넣을 칸이 없다(서버가 모르는 키를 거부한다).
// 마지막으로 보낸 내용은 SharedPreferences 에 둔다(같은 내용 반복 전송 금지). 실패는 조용히 넘기고 재시도하지 않는다.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'report_env.dart';

class SetupProgressReporter {
  SetupProgressReporter._();

  static const prefsLast = 'setup_progress.last';
  static const prefsDone = 'setup_progress.done';
  static const maxBodyBytes = 2048;
  static const timeout = Duration(seconds: 15);

  static const stages = {
    'kakao_ok',
    'consent_ok',
    'client_server_checked',
    'official_login_started',
    'official_login_failed',
    'official_login_ok',
    'connection_registered',
  };
  static const modes = {'standalone', 'client', 'demo', 'unselected'};
  static const clientKeys = {
    'server_reachable',
    'server_version',
    'server_community_supported',
    'server_logged_in',
    'server_consent_active',
    'account_match',
  };
  static final _code = RegExp(r'^[a-z0-9_]{1,40}$');
  static final _version = RegExp(r'^[0-9][0-9A-Za-z.+_-]{0,39}$');

  /// 마지막 응답 상태(진단용). 200 이 아니면 그 단계는 "보낸 것"으로 치지 않는다.
  static int? lastStatus;

  /// 단계가 바뀌었을 때만 보낸다. 아무것도 던지지 않는다.
  static Future<void> report({
    required String stage,
    String? reason,
    required String mode,
    Map<String, Object?>? client,
  }) async {
    try {
      await _run(stage, reason, mode, client);
    } catch (_) {}
  }

  /// 본문을 만든다. 형식이 틀리면 null. (시험용으로 공개)
  static Map<String, Object?>? buildBody({
    required String clientVersion,
    required String platform,
    required String stage,
    String? reason,
    required String mode,
    Map<String, Object?>? client,
  }) {
    if (!stages.contains(stage) || !modes.contains(mode)) return null;
    if (!_version.hasMatch(clientVersion)) return null;
    if (!const {'android', 'ios', 'other'}.contains(platform)) return null;

    Map<String, Object?>? clientOut;
    if (stage == 'client_server_checked') {
      if (mode != 'client') return null;
      clientOut = _checkedClient(client);
      if (clientOut == null) return null;
    }
    String? reasonOut;
    if (stage == 'official_login_failed' && reason != null) {
      // 앱이 이미 쓰는 실패 코드만. 형식이 다르면(문장·주소 등) 값을 버리고 'other'.
      reasonOut = _code.hasMatch(reason) ? reason : 'other';
    }
    return {
      'protocol': 1,
      'client_version': clientVersion,
      'source_app': 'safetyreport-mobile',
      'platform': platform,
      'mode': mode,
      'stage': stage,
      'reason': reasonOut,
      'client': clientOut,
    };
  }

  /// 정확히 6키, 값 형식 검사. 틀리면 null.
  static Map<String, Object?>? _checkedClient(Map<String, Object?>? c) {
    if (c == null || c.length != clientKeys.length) return null;
    if (!c.keys.every(clientKeys.contains)) return null;
    final reachable = c['server_reachable'];
    if (reachable is! bool) return null;
    final version = c['server_version'];
    if (version != null && !(version is String && _version.hasMatch(version))) {
      return null;
    }
    for (final k in const [
      'server_community_supported',
      'server_logged_in',
      'server_consent_active',
      'account_match',
    ]) {
      final v = c[k];
      if (v != null && v is! bool) return null;
    }
    return {for (final k in clientKeys) k: c[k]};
  }

  static Future<void> _run(
    String stage,
    String? reason,
    String mode,
    Map<String, Object?>? client,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // 다른 isolate 가 쓴 값을 본다.
    // 새 로그인 흐름의 시작이면 "연결 등록 뒤 중단" 표시를 푼다.
    if (stage == 'kakao_ok') await prefs.remove(prefsDone);
    if (prefs.getBool(prefsDone) == true) return;

    final cfg = ReportEnv.config;
    if (!cfg.isConfigured) return;
    final version = await ReportEnv.appVersion();
    if (version == null) return;
    final body = buildBody(
      clientVersion: version,
      platform: ReportEnv.platform(),
      stage: stage,
      reason: reason,
      mode: mode,
      client: client,
    );
    if (body == null) return;
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > maxBodyBytes) return;
    final signature = jsonEncode([
      body['stage'],
      body['reason'],
      body['mode'],
      body['client'],
    ]);
    if (prefs.getString(prefsLast) == signature) return;

    final token = await ReportEnv.accessToken();
    if (token == null || token.isEmpty) return;
    final client0 = ReportEnv.newClient();
    try {
      final res = await client0
          .post(
            Uri.parse(
              '${cfg.supabaseUrl}/functions/v1/community-account/setup-progress',
            ),
            headers: {
              'apikey': cfg.publishableKey,
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'X-Client-Version': version,
              'X-Client-App': ReportEnv.clientApp(),
            },
            body: bytes,
          )
          .timeout(timeout);
      lastStatus = res.statusCode;
      if (res.statusCode == 200) {
        await prefs.setString(prefsLast, signature);
        if (stage == 'connection_registered') {
          await prefs.setBool(prefsDone, true);
        }
      }
      // 429 등은 기록하지 않는다 — 그 단계는 다음 변화(또는 다음 호출) 때 다시 보낸다.
    } on TimeoutException {
      lastStatus = null;
    } on http.ClientException {
      lastStatus = null;
    }
  }
}
