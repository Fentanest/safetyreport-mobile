import 'package:flutter/material.dart';

import '../services/community_auth_service.dart';
import '../services/local_db_service.dart';
import 'gate/community_gate.dart';

/// 카카오 로그아웃 = 이 기기의 신고 자료 삭제 (2026-09-27 사용자 결정, PC `POST /settings/community/logout` 과 같은 규칙).
///
/// - 카카오 로그인은 필수다. 로그인만 푸는 "연결 해제"는 쓰지 않는다(주석 처리).
/// - Standalone(데모 제외)만 자료를 지운다. 남기는 것은 감시목록·지오코딩 캐시([LocalDbService.wipeReportData]).
/// - 지금 로그인한 카카오 계정이 자료 주인과 **다르다고 확인된** 경우만 자료를 남긴다(다른 계정의 자료이므로).
/// - 동기화·지도 변환 중이면 아무것도 지우지 않고 로그인도 그대로 둔다.
class KakaoLogout {
  KakaoLogout._();

  /// 이 로그아웃이 신고 자료를 지우는가. 주인 표시를 읽지 못하면 예외 — 호출자는 로그아웃하지 않는다
  /// ("주인 없음"으로 보고 남의 자료를 지우지 않게, PC `_logout_wipes` 와 같음).
  static Future<bool> wipesData({
    required CommunityGate? gate,
    required CommunityAuthService auth,
    Future<String?> Function()? dbOwner,
  }) async {
    if (gate != null && !gate.isWriter) return false;
    final owner = await (dbOwner ?? LocalDbService.dbOwner)();
    final kakao = await auth.sessionKakaoId();
    return !(owner != null && kakao != null && owner != kakao);
  }

  /// 확인 창 → (자료 삭제) → 카카오 로그아웃. 로그아웃했으면 true.
  /// [wipe] 는 시험용 주입(기본 [LocalDbService.wipeReportData]).
  static Future<bool> confirmAndRun(
    BuildContext context, {
    required CommunityGate? gate,
    required CommunityAuthService auth,
    Future<String?> Function()? dbOwner,
    Future<void> Function(String reason)? wipe,
    Future<void> Function()? afterWipe,
  }) async {
    final bool wipes;
    try {
      wipes = await wipesData(gate: gate, auth: auth, dbOwner: dbOwner);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('저장된 신고 내역을 확인하지 못해 로그아웃하지 않았습니다. 잠시 뒤 다시 시도하세요.'),
        ));
      }
      return false;
    }
    if (!context.mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('카카오 로그아웃'),
        content: Text(
          wipes
              ? '로그아웃하면 이 기기에 저장된 신고 내역이 모두 지워집니다. '
                  '다시 로그인하면 안전신문고에서 신고 내역을 처음부터 다시 불러와야 합니다(감시 목록은 남습니다).'
              : '카카오 계정에서 로그아웃합니다. 로그인하기 전까지 앱을 쓸 수 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: wipes
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(wipes ? '지우고 로그아웃' : '로그아웃'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    final error = await run(gate: gate, auth: auth, wipes: wipes, wipe: wipe, afterWipe: afterWipe);
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
    return error == null;
  }

  /// 로그아웃 실행. 실패(지우지 못함)면 사용자에게 보일 문장, 성공이면 null.
  static Future<String?> run({
    required CommunityGate? gate,
    required CommunityAuthService auth,
    required bool wipes,
    Future<void> Function(String reason)? wipe,
    Future<void> Function()? afterWipe,
  }) async {
    if (wipes) {
      try {
        await (wipe ?? (r) => LocalDbService.wipeReportData(r))('kakao_logout');
      } on DbBusyException catch (e) {
        return e.message;
      } catch (_) {
        return '신고 내역을 지우지 못해 로그아웃하지 않았습니다. 잠시 뒤 다시 시도하세요.';
      }
      try {
        await afterWipe?.call();
      } catch (_) {}
    }
    gate?.invalidate('logout');
    await auth.disconnect();
    gate?.invalidate('logout');
    return null;
  }

  /// 이 기기의 신고 자료가 다른 카카오 계정 것일 때(게이트 `db_owner_mismatch`): 그 자료를 지우고 지금 계정으로 시작한다.
  static Future<String?> adopt({
    required CommunityGate gate,
    required CommunityAuthService auth,
    Future<void> Function(String reason, String owner)? wipe,
    Future<void> Function()? afterWipe,
  }) async {
    if (gate.state.state != 'db_owner_mismatch') return '지금은 이 작업을 할 수 없습니다.';
    final String? kakao;
    try {
      kakao = await auth.currentKakaoId();
    } catch (_) {
      return '카카오 계정을 확인하지 못했습니다. 잠시 뒤 다시 시도하세요.';
    }
    if (kakao == null) return '카카오 로그인이 필요합니다.';
    try {
      await (wipe ?? (r, o) => LocalDbService.wipeReportData(r, thenOwner: o))('db_owner_adopt', kakao);
    } on DbBusyException catch (e) {
      return e.message;
    } catch (_) {
      return '신고 내역을 지우지 못했습니다. 잠시 뒤 다시 시도하세요.';
    }
    try {
      await afterWipe?.call();
    } catch (_) {}
    gate.invalidate('db_owner_adopt');
    await gate.refreshNow();
    return null;
  }
}
