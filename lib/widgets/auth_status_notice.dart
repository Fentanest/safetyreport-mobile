import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../screens/settings_screen.dart';
import '../services/standalone_auth_service.dart';
import '../theme/sr_colors.dart';

String _fmt(DateTime t) =>
    '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Standalone 에서 자동 로그인으로 해결할 수 없을 때(비밀번호 거부·로그인 정보 없음)만 보이는 경고.
/// 대시보드·동기화 화면 맨 위. 네트워크·점검 같은 일시 오류에는 띄우지 않는다.
class ReloginRequiredBanner extends StatelessWidget {
  const ReloginRequiredBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    if (provider.appMode != AppMode.standalone || provider.isStandaloneDemo) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<ReloginStatus?>(
      valueListenable: StandaloneAuthService.status,
      builder: (context, status, _) {
        if (status == null || !status.needsManualLogin) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final tone = StatusTone.of(
          theme.colorScheme.error,
          brightness: theme.brightness,
          surface: theme.colorScheme.surface,
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: tone.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tone.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lock_reset, color: tone.foreground, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '안전신문고 재로그인이 필요합니다',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: tone.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  status.message,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const SettingsScreen(openReloginOnStart: true),
                      ),
                    ),
                    child: const Text('재로그인'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 설정 > 안전신문고 계정 카드의 "마지막 로그인" 한 줄(+ 실패 사유).
class AuthStatusLine extends StatelessWidget {
  const AuthStatusLine({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReloginStatus?>(
      valueListenable: StandaloneAuthService.status,
      builder: (context, status, _) {
        final sr = context.sr;
        if (status == null) {
          return Text(
            '마지막 로그인 기록 없음',
            style: TextStyle(fontSize: 12, color: sr.textSecondary),
          );
        }
        final label = switch (status.outcome) {
          ReloginOutcome.success => '성공',
          ReloginOutcome.transient => '연결 실패(잠시 후 자동 재시도)',
          ReloginOutcome.rejected => '거부됨 — 재로그인 필요',
          ReloginOutcome.noCredentials => '로그인 정보 없음 — 재로그인 필요',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '마지막 로그인: ${_fmt(status.at)} $label',
              style: TextStyle(
                fontSize: 12,
                fontWeight: status.needsManualLogin
                    ? FontWeight.bold
                    : FontWeight.normal,
                color: status.needsManualLogin
                    ? Theme.of(context).colorScheme.error
                    : sr.textSecondary,
              ),
            ),
            if (status.outcome != ReloginOutcome.success &&
                status.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  status.message,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: sr.textSecondary,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
