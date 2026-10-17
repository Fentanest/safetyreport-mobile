import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/db_failure.dart';
import '../widgets/sr_snack_bar.dart';

/// Standalone '신고 내역 다시 불러오기' 필요 판정이 실패했을 때의 화면(2026-10-17 제보 대응).
///
/// 예전에는 원인 없이 '다시 시도'만 있어, 같은 실패가 반복되면 앱에 들어갈 수 없었다.
/// - 원인별 안내(저장공간 부족·DB 잠금·그 밖)와 복사 가능한 오류 내용(제보용).
/// - '기존 자료로 들어가기': 판정 없이 메인으로 간다. 다시 불러오기가 필요한데 아직 모르면 일반 동기화는
///   [SyncEngine.rebuildBlocks] 가 막는다(확인 실패도 막음 — fail-closed). 판정은 다음 실행 때 다시 한다.
/// - '앱 완전히 종료': 같은 프로세스에서 멈춘 백그라운드 작업이 잠금을 쥐고 있으면 다시 시도로는 풀리지 않는다.
class RebuildPrepareFailureScreen extends StatelessWidget {
  const RebuildPrepareFailureScreen({
    super.key,
    required this.kind,
    required this.detail,
    required this.onRetry,
    required this.onEnter,
    required this.onExit,
    this.exiting = false,
  });

  final DbFailureKind kind;
  final String detail;
  final VoidCallback onRetry;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final bool exiting;

  static String messageFor(DbFailureKind kind) => switch (kind) {
    DbFailureKind.storageFull =>
      '휴대폰 저장공간이 부족해 신고 자료를 열지 못했습니다. 앱이 만든 임시 파일은 정리했습니다. '
          '기존 자료는 그대로입니다.\n휴대폰 저장공간을 확보한 뒤 다시 시도해 주세요.',
    DbFailureKind.locked =>
      '백그라운드 작업(동기화·업로드)이 신고 자료를 쓰고 있어 다시 불러오기가 필요한지 확인하지 못했습니다. '
          '기존 자료는 그대로입니다.\n잠시 후 다시 시도하거나, 앱을 완전히 종료한 뒤 다시 열어 주세요.',
    DbFailureKind.other =>
      '다시 불러오기가 필요한지 확인하지 못했습니다. 기존 자료는 그대로입니다. 잠시 후 다시 시도해 주세요.\n'
          '계속 안 되면 앱을 완전히 종료한 뒤 다시 열어 주세요.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('신고 내역 다시 불러오기')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(messageFor(kind), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('rebuildPrepareRetry'),
                  onPressed: exiting ? null : onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('다시 시도'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('rebuildPrepareEnter'),
                  onPressed: exiting ? null : onEnter,
                  icon: const Icon(Icons.login),
                  label: const Text('기존 자료로 들어가기'),
                ),
                if (kind != DbFailureKind.storageFull) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('rebuildPrepareExit'),
                    onPressed: exiting ? null : onExit,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('앱 완전히 종료'),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '기존 자료로 들어가면 다시 불러오기 확인은 다음에 앱을 열 때 합니다. '
                  '확인이 끝날 때까지 동기화가 시작되지 않을 수 있습니다.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                Text(
                  '오류 내용(문의할 때 함께 보내 주세요)',
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  detail,
                  key: const Key('rebuildPrepareDetail'),
                  style: theme.textTheme.bodySmall,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('rebuildPrepareCopy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: detail));
                      if (context.mounted) {
                        showSrSnack(context, '오류 내용을 복사했습니다.');
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('복사'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
