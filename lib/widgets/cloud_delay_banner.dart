import 'dart:async';
import 'package:flutter/material.dart';
import '../community/gate/community_gate.dart';

/// The one-second tick only renders local time. It never triggers HTTP.
class CloudDelayBanner extends StatefulWidget {
  const CloudDelayBanner({super.key, required this.gate});
  final CommunityGate gate;
  @override
  State<CloudDelayBanner> createState() => _CloudDelayBannerState();
}

class _CloudDelayBannerState extends State<CloudDelayBanner> {
  Timer? _tick;
  int _pending = 0;
  int _ticks = 0;
  @override
  void initState() {
    super.initState();
    widget.gate.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
      if (++_ticks % 5 == 0) _changed();
    });
    _changed();
  }

  void _changed() {
    widget.gate
        .pendingUploads()
        .then((n) {
          if (mounted) setState(() => _pending = n);
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    widget.gate.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gate = widget.gate;
    if (gate.state.state != 'cloud_unavailable') return const SizedBox.shrink();
    final seconds =
        (gate.nextCloudAttempt?.difference(DateTime.now()).inSeconds ?? 0)
            .clamp(0, 8640000);
    final clock =
        '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    final checking = seconds == 0 ? '연결 확인 대기 중' : '$clock 후 다시 확인';
    return SafeArea(
      bottom: false,
      child: Material(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: SizedBox(
            width: double.infinity,
            child: Text(
              '서버 연결 지연 · $checking · ${_pending > 0 ? '업로드 대기 중 ($_pending건)' : '대기 중인 업로드 없음'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
    );
  }
}
