import 'package:flutter/material.dart';

import '../community/upload_pause.dart';

/// 서버 점검(업로드 일시 중지) 상단 안내 — CLIENT-RULES 5절·11절 문구.
/// 사용자가 할 일이 없다: 시각이 있으면 언제 다시 올리는지, 없으면 점검이 끝나면 자동으로 올린다고만 알린다.
/// 운영자 문구(`pause_message`)는 다음 줄에 평문으로 보인다(HTML·마크다운으로 해석하지 않는다).
class UploadPauseBanner extends StatelessWidget {
  const UploadPauseBanner({super.key, this.now});

  /// 시험용 시각.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UploadPause?>(
    valueListenable: UploadPause.current,
    builder: (context, pause, _) {
      if (pause == null) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return SafeArea(
        bottom: false,
        child: Material(
          key: const Key('uploadPauseBanner'),
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.cloud_off_outlined,
                  size: 18,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        uploadPauseBannerText(pause, now: now?.call()),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                      if (pause.message != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          pause.message!,
                          key: const Key('uploadPauseMessage'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
