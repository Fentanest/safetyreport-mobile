// 업데이트 뒤 한 번 훑기 작업 진행 — 화면 하단(탭 위) 한 줄 박스. 서버 웹 base.html 의 #srJobBar 와 같은 모양·문구.
// 작업이 없으면 아무것도 그리지 않는다. 끝나면 "완료"를 잠깐 보여 주고 사라진다.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/maintenance_service.dart';
import '../theme/sr_colors.dart';

class MaintenanceStatusBar extends StatefulWidget {
  const MaintenanceStatusBar({super.key, this.fetchServerStatus});

  /// Client 모드: 서버 진행 상태를 읽는 함수(`ApiService.fetchMaintenanceStatus`). null 이면 Standalone(로컬 작업).
  final Future<Map<String, dynamic>?> Function()? fetchServerStatus;

  @override
  State<MaintenanceStatusBar> createState() => _MaintenanceStatusBarState();
}

class _MaintenanceStatusBarState extends State<MaintenanceStatusBar>
    with WidgetsBindingObserver {
  List<MaintenanceJob> _jobs = const [];
  bool _wasActive = false;
  String? _doneText;
  Timer? _timer;
  Timer? _hideTimer;

  /// 앱이 보이는가. hidden/paused 면 확인을 멈추고 resumed 에서 즉시 한 번 확인한다(SQ-P04).
  bool _foreground = true;
  bool _inFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MaintenanceService.photoJob.addListener(_refreshLocal);
    _foreground = !_isBackground(WidgetsBinding.instance.lifecycleState);
    if (_foreground) _tick();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MaintenanceService.photoJob.removeListener(_refreshLocal);
    _timer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  static bool _isBackground(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_foreground) return;
      _foreground = true;
      _tick();
    } else if (_isBackground(state)) {
      _foreground = false;
      _timer?.cancel();
      _timer = null;
    }
  }

  void _refreshLocal() {
    if (widget.fetchServerStatus == null) {
      _apply(MaintenanceService.localJobs());
    }
  }

  Future<void> _tick() async {
    // 복귀 확인과 예약 확인이 겹치면 진행 중인 요청 하나가 끝난 뒤 다음 주기를 잡는다.
    if (_inFlight || !mounted) return;
    _timer?.cancel();
    _timer = null;
    List<MaintenanceJob>? jobs;
    final fetch = widget.fetchServerStatus;
    _inFlight = true;
    try {
      jobs = fetch == null
          ? MaintenanceService.localJobs()
          : MaintenanceService.jobsFromServer(await fetch());
    } catch (_) {
      jobs = null; // 일시 오류 — 표시는 그대로 두고 다음 주기에 다시 본다.
    } finally {
      _inFlight = false;
    }
    if (!mounted) return;
    if (jobs != null) _apply(jobs);
    // 백그라운드로 간 사이 끝난 요청은 다음 주기를 예약하지 않는다(복귀 때 즉시 확인).
    if (!_foreground) return;
    final active = jobs?.any((j) => j.active) ?? _wasActive;
    _timer?.cancel();
    _timer = Timer(
      active ? const Duration(seconds: 2) : const Duration(seconds: 30),
      _tick,
    );
  }

  static bool _sameJobs(List<MaintenanceJob> a, List<MaintenanceJob> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.key != y.key ||
          x.label != y.label ||
          x.state != y.state ||
          x.total != y.total ||
          x.done != y.done ||
          x.current != y.current ||
          x.message != y.message) {
        return false;
      }
    }
    return true;
  }

  /// 표시가 실제로 바뀔 때만 다시 그린다(같은 결과면 setState 하지 않는다).
  void _apply(List<MaintenanceJob> jobs) {
    if (!mounted) return;
    final active = jobs.any((j) => j.active);
    if (active) {
      final activeJobs = jobs.where((j) => j.active).toList();
      if (_wasActive && _doneText == null && _sameJobs(activeJobs, _jobs)) {
        return;
      }
      _hideTimer?.cancel();
      setState(() {
        _jobs = activeJobs;
        _doneText = null;
        _wasActive = true;
      });
    } else if (_wasActive) {
      final done = jobs.where((j) => j.state == 'completed').toList();
      _hideTimer?.cancel();
      setState(() {
        _doneText = done.isEmpty
            ? '작업 완료'
            : done
                  .map(
                    (j) =>
                        '${j.label} 완료${j.message.isEmpty ? '' : ' · ${j.message}'}',
                  )
                  .join('   |   ');
        _jobs = const [];
        _wasActive = false;
      });
      _hideTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _doneText = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_jobs.isEmpty && _doneText == null) return const SizedBox.shrink();
    final sr = context.sr;
    final paused = _jobs.isNotEmpty && _jobs.every((j) => j.state == 'paused');
    final text = _doneText ?? _jobs.map((j) => j.line).join('   |   ');
    return Semantics(
      liveRegion: true,
      label: text,
      child: Container(
        key: const Key('maintenance-status-bar'),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
        decoration: BoxDecoration(
          color: sr.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: sr.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            _doneText != null
                ? Icon(
                    Icons.check_circle,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : BusyRing(size: 18, color: sr.brand, slow: paused),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: paused ? sr.textSecondary : sr.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 비스타풍 대기 표시: 옅은 원형 링 위를 밝은 호가 돈다(테마 강조색).
class BusyRing extends StatefulWidget {
  const BusyRing({
    super.key,
    required this.size,
    required this.color,
    this.slow = false,
  });
  final double size;
  final Color color;
  final bool slow;

  @override
  State<BusyRing> createState() => _BusyRingState();
}

class _BusyRingState extends State<BusyRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.slow
        ? const Duration(seconds: 3)
        : const Duration(seconds: 1),
  )..repeat();

  @override
  void didUpdateWidget(BusyRing old) {
    super.didUpdateWidget(old);
    if (old.slow != widget.slow) {
      _c.duration = widget.slow
          ? const Duration(seconds: 3)
          : const Duration(seconds: 1);
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _c,
    child: CustomPaint(
      size: Size.square(widget.size),
      painter: _RingPainter(widget.color),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final rect = Offset.zero & size;
    final ring = rect.deflate(stroke / 2);
    canvas.drawArc(
      ring,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: 0.18),
    );
    canvas.drawArc(
      ring,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: 0.35),
            color,
            Colors.white,
            color,
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.4, 0.78, 0.88, 0.94, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color;
}
