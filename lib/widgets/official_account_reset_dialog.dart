import 'package:flutter/material.dart';

/// 재로그인과 최초 설정이 같은 자료 분리 안내를 사용한다.
Future<bool> confirmOfficialAccountReset(BuildContext context) async {
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('안전신문고 계정별 자료 분리'),
          content: const Text(
            '안전신문고 계정을 변경하려고 합니다. '
            '기존 데이터가 지워집니다. 먼저 개인 DB를 Documents/mysafetyreport에 백업합니다'
            '(저장할 수 없으면 Download/mysafetyreport). '
            '기존 커뮤니티 공유자료와 계정 연결을 삭제한 뒤 이 기기의 신고 내역과 감시 목록을 비우고 새로 시작합니다. '
            '안전신문고에 접수한 신고 원본은 유지됩니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('자료 비우고 계속'),
            ),
          ],
        ),
      ) ??
      false;
}
