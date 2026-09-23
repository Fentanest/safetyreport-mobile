import 'package:flutter/material.dart';

import '../models/app_mode.dart';
import '../theme/sr_colors.dart';

/// 실행 모드 표시(D-03). primary 가 두 모드 공통이 되면서 모드 구분을 이 배지가 맡는다.
class ModeBadge extends StatelessWidget {
  final AppMode mode;
  final bool isDemo;

  const ModeBadge({super.key, required this.mode, this.isDemo = false});

  @override
  Widget build(BuildContext context) {
    final sr = context.sr;
    final isStandalone = mode == AppMode.standalone;
    final base = isStandalone ? sr.modeStandalone : sr.modeClient;
    final tone = StatusTone.of(
      base,
      brightness: Theme.of(context).brightness,
      surface: sr.background,
    );
    final label = isStandalone
        ? (isDemo ? 'Standalone · 데모' : 'Standalone')
        : 'Client';
    return Semantics(
      label: '실행 모드 $label',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tone.background,
          border: Border.all(color: tone.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isStandalone ? Icons.phone_android_rounded : Icons.dns_rounded,
              size: 13,
              color: tone.foreground,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: tone.foreground,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
