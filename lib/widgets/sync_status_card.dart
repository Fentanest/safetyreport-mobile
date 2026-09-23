import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../navigation/app_routes.dart';
import '../providers/report_provider.dart';
import '../services/sync_engine.dart';
import '../theme/sr_colors.dart';

/// 하단 탭에서 빠진 동기화(Standalone)/크롤링(Client) 화면으로 가는 대시보드 진입점 (D-06).
/// 실제 실행·설정은 기존 CrawlScreen 이 그대로 담당한다(모드 혼합 없음).
class SyncStatusCard extends StatefulWidget {
  const SyncStatusCard({super.key});

  @override
  State<SyncStatusCard> createState() => _SyncStatusCardState();
}

class _SyncStatusCardState extends State<SyncStatusCard> {
  Future<String?>? _lastSync;
  bool? _lastSyncing;
  AppMode? _lastMode;

  void _refreshIfNeeded(ReportProvider p) {
    if (_lastSync != null &&
        _lastSyncing == p.isSyncing &&
        _lastMode == p.appMode) {
      return;
    }
    _lastSyncing = p.isSyncing;
    _lastMode = p.appMode;
    _lastSync = p.appMode == AppMode.standalone
        ? SyncEngine.getLastSyncTime().catchError((_) => null)
        : Future.value(null);
  }

  static String _format(String? iso) {
    final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '아직 동기화 기록이 없습니다';
    String two(int v) => v.toString().padLeft(2, '0');
    return '마지막 동기화 ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ReportProvider>();
    _refreshIfNeeded(p);
    final sr = context.sr;
    final scheme = Theme.of(context).colorScheme;
    final isStandalone = p.appMode == AppMode.standalone;
    final title = isStandalone ? '동기화' : '크롤링';

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => AppRoutes.openCrawl(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: sr.brandSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: p.isSyncing
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: scheme.primary,
                          ),
                        )
                      : Icon(Icons.sync_rounded, color: scheme.primary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$title 상태',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: sr.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (p.isSyncing)
                      Text(
                        '$title 진행 중…',
                        style: TextStyle(fontSize: 12, color: sr.textSecondary),
                      )
                    else if (!isStandalone)
                      Text(
                        '서버 크롤링 실행·상태·로그는 크롤링 화면에서 확인합니다',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: sr.textSecondary),
                      )
                    else if (p.isStandaloneDemo)
                      Text(
                        '데모 모드에서는 동기화를 실행할 수 없습니다',
                        style: TextStyle(fontSize: 12, color: sr.textSecondary),
                      )
                    else
                      FutureBuilder<String?>(
                        future: _lastSync,
                        builder: (context, snap) => Text(
                          snap.connectionState == ConnectionState.done
                              ? _format(snap.data)
                              : '마지막 동기화 확인 중…',
                          style: TextStyle(
                            fontSize: 12,
                            color: sr.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$title 화면',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                  Icon(Icons.chevron_right, color: scheme.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 대시보드 앱바의 동기화/크롤링 버튼. 진행 중이면 아이콘이 돈다(이전 하단 탭 아이콘 동작 이관).
class SyncActionButton extends StatefulWidget {
  const SyncActionButton({super.key});

  @override
  State<SyncActionButton> createState() => _SyncActionButtonState();
}

class _SyncActionButtonState extends State<SyncActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ReportProvider>();
    if (p.isSyncing) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
    final label = p.appMode == AppMode.standalone ? '동기화' : '크롤링';
    return IconButton(
      tooltip: label,
      onPressed: () => AppRoutes.openCrawl(context),
      icon: RotationTransition(
        turns: Tween<double>(begin: 0, end: -1).animate(_controller),
        child: const Icon(Icons.sync),
      ),
    );
  }
}
