// 가져오기·복원은 주인(카카오 회원번호)이 지금 로그인한 계정과 같은 DB 만 받는다(2026-09-27 사용자 결정).
// 교환 규칙을 보는 기존 시험은 모두 이 계정의 DB 로 한다 — 주인 검사 자체는 test/storage/account_owner_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const testKakaoId = '910001';

/// 이 파일의 시험 동안 "지금 로그인한 카카오 계정"을 [testKakaoId] 로 둔다.
void useTestKakaoAccount() {
  final original = LocalDbService.currentKakaoId;
  setUp(() => LocalDbService.currentKakaoId = () async => testKakaoId);
  tearDown(() => LocalDbService.currentKakaoId = original);
}

/// DB 에 주인을 적는다. 서버 DB 는 `mysafety_sync_meta`, 모바일 DB 는 `sync_meta`.
Future<void> stampOwner(
  DatabaseExecutor db, {
  String table = 'sync_meta',
  String owner = testKakaoId,
}) =>
    db.insert(
      table,
      {'key': LocalDbService.kakaoMemberMetaKey, 'value': owner},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
