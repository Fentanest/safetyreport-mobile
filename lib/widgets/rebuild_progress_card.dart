import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../community/rebuild/community_rebuild.dart';
import '../community/rebuild/standalone_rebuild_runner.dart';
import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../screens/community_rebuild_screen.dart';
import '../theme/sr_colors.dart';
import '../theme/sr_tokens.dart';

/// Standalone 신고 내역 다시 불러오기(1회) 진행 카드 — 대시보드·동기화 화면 위(2026-10-11 사용자 결정: 백그라운드).
///
/// 진행률·완료·일부 누락·실패 재시도를 보이고, 일시정지·이어서 진행·누락 확인·자세히(기존 [CommunityRebuildScreen])를 연다.
/// 카드가 없어도 작업은 [StandaloneRebuildRunner] 가 계속한다. Client·데모에서는 그리지 않는다.
class RebuildProgressCard extends StatelessWidget {
  const RebuildProgressCard({super.key, this.runner, this.bottomSpacing = 12});

  /// 시험용. 없으면 앱 전역 [StandaloneRebuildRunner.instance].
  final StandaloneRebuildRunner? runner;

  /// 카드가 보일 때만 아래에 두는 간격(숨겨지면 간격도 없다).
  final double bottomSpacing;

  @override
  Widget build(BuildContext context) {
    final applies = context.select<ReportProvider, bool>(
      (p) => p.appMode == AppMode.standalone && !p.isStandaloneDemo,
    );
    if (!applies) return const SizedBox.shrink();
    final r = runner ?? StandaloneRebuildRunner.instance;
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) {
        final rebuild = r.current;
        if (!r.visible || rebuild == null) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(bottom: bottomSpacing),
          child: _Card(runner: r, rebuild: rebuild),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.runner, required this.rebuild});

  final StandaloneRebuildRunner runner;
  final CommunityRebuild rebuild;

  SrTone _tone(RebuildProgress p) {
    if (p.done) {
      return p.state == RebuildStates.completedWithGaps
          ? SrTone.warning
          : SrTone.success;
    }
    if (p.executing || p.waitingForWorker) return SrTone.primary;
    if (p.state == RebuildStates.failed || p.needsGapConsent) {
      return SrTone.warning;
    }
    return SrTone.neutral;
  }

  IconData _icon(RebuildProgress p) {
    if (p.done) {
      return p.state == RebuildStates.completedWithGaps
          ? Icons.task_alt_rounded
          : Icons.check_circle_rounded;
    }
    if (p.needsGapConsent || p.state == RebuildStates.failed) {
      return Icons.error_outline_rounded;
    }
    if (p.state == RebuildStates.paused) return Icons.pause_circle_outline;
    return Icons.cloud_download_outlined;
  }

  Future<void> _acceptGaps(BuildContext context, int gaps) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('가져오지 못한 신고'),
        content: Text(
          '안전신문고에서 가져오지 못한 신고 $gaps건은 기존 자료를 그대로 두고 다시 불러오기를 마칩니다. '
          '자세한 목록은 \'자세히\' 에서 볼 수 있습니다. 계속할까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('확인하고 마무리'),
          ),
        ],
      ),
    );
    if (ok == true) runner.acceptGapsInBackground();
  }

  void _openDetail(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CommunityRebuildScreen(rebuild: rebuild),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = RebuildProgress.of(rebuild);
    final sr = context.sr;
    final scheme = Theme.of(context).colorScheme;
    final tone = context.tone(_tone(p));
    final fraction = p.fraction;
    final notice = !p.executing && !p.done ? p.notice : null;

    final buttons = <Widget>[
      if (p.executing)
        OutlinedButton.icon(
          key: const Key('rebuildCardPause'),
          icon: const Icon(Icons.pause_rounded),
          label: Text(p.stopping ? '중단 확인 중…' : '일시정지'),
          onPressed: p.stopping ? null : runner.requestPause,
        )
      else if (p.needsGapConsent)
        FilledButton(
          key: const Key('rebuildCardAcceptGaps'),
          onPressed: () => _acceptGaps(context, p.failedPermanent),
          child: Text('누락 ${p.failedPermanent}건 확인하고 마무리'),
        )
      else if (!p.done)
        FilledButton.icon(
          key: const Key('rebuildCardResume'),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(
            p.state == RebuildStates.failed
                ? '다시 시도'
                : rebuild.job == null
                ? '시작'
                : '이어서 진행',
          ),
          onPressed: () => runner.runInBackground(confirmedBy: 'resume'),
        ),
      TextButton(
        key: const Key('rebuildCardDetail'),
        onPressed: () => _openDetail(context),
        child: const Text('자세히'),
      ),
    ];

    return Card(
      key: const Key('rebuildProgressCard'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: tone.background,
                    borderRadius: BorderRadius.circular(SrRadius.lg),
                  ),
                  child: Center(
                    child: p.executing
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: scheme.primary,
                            ),
                          )
                        : Icon(_icon(p), color: tone.foreground),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '신고 내역 다시 불러오기',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            color: sr.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          p.headline,
                          key: const Key('rebuildCardHeadline'),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: p.executing
                                ? sr.textPrimary
                                : tone.foreground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (p.done)
                  IconButton(
                    key: const Key('rebuildCardDismiss'),
                    tooltip: '닫기',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: runner.dismissCompletion,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 10, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (fraction != null || p.executing) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(SrRadius.sm),
                      child: LinearProgressIndicator(
                        key: const Key('rebuildCardProgress'),
                        value: fraction,
                        minHeight: 6,
                        semanticsLabel: '신고 내역 다시 불러오기 진행률',
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (p.countsLine.isNotEmpty)
                    Text(
                      p.countsLine,
                      key: const Key('rebuildCardCounts'),
                      style: TextStyle(fontSize: 12, color: sr.textSecondary),
                    ),
                  if (p.done && (p.pendingUploads ?? 0) > 0)
                    Text(
                      '공유 전송 대기 ${p.pendingUploads}건은 이어서 보냅니다.',
                      style: TextStyle(fontSize: 12, color: sr.textSecondary),
                    ),
                  if (notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        notice,
                        key: const Key('rebuildCardNotice'),
                        style: TextStyle(fontSize: 12, color: sr.textSecondary),
                      ),
                    ),
                  if (p.executing)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '진행 중에도 기존 자료를 그대로 볼 수 있습니다. 일반 동기화는 끝난 뒤에 할 수 있습니다.',
                        style: TextStyle(fontSize: 12, color: sr.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, children: buttons),
          ],
        ),
      ),
    );
  }
}
