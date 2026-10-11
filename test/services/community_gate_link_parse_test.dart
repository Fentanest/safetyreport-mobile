// PC 라우트 오류 응답의 문구는 `detail` 키에 있다 — 모바일이 그 문구를 그대로 보여야 한다(전엔 'HTTP 403' 일반 문구).
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/community_server_link_service.dart';

void main() {
  test('detail 문구를 message 로 쓴다(503 cloud_unavailable)', () {
    final r = CommunityGateLinkResult.parse(
      503,
      '{"detail":"클라우드에 연결할 수 없어 사용자를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.","code":"cloud_unavailable"}',
    );
    expect(r.code, 'cloud_unavailable');
    expect(r.message, contains('잠시 후 다시 시도'));
  });

  test('message 가 있으면 message 가 우선', () {
    final r = CommunityGateLinkResult.parse(
      503,
      '{"detail":"d","message":"m","code":"cloud_unavailable"}',
    );
    expect(r.message, 'm');
  });

  test('문구가 없으면 기존 일반 문구', () {
    final r = CommunityGateLinkResult.parse(500, '{"code":"x"}');
    expect(r.message, '서버 오류: HTTP 500');
  });

  test('permission_required 는 기존 안내 그대로', () {
    final r = CommunityGateLinkResult.parse(
      403,
      '{"detail":"커뮤니티 관리 권한이 없는 키입니다.","code":"permission_required"}',
    );
    expect(r.message, CommunityGateLinkResult.permissionMessage);
  });
}
