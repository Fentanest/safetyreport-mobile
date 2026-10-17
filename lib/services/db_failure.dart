import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// 시작 판정·DB 열기 실패의 종류. 사용자 안내와 복구 방법이 다르다(2026-10-17 사용자 제보: 캐시 삭제 뒤 정상).
enum DbFailureKind {
  /// 저장공간 부족(SQLITE_FULL, ENOSPC). 임시 파일을 정리하면 풀릴 수 있다.
  storageFull,

  /// 다른 연결이 쓰기 잠금을 쥐고 있다(SQLITE_BUSY·SQLITE_LOCKED). 같은 프로세스의 멈춘 백그라운드 작업이면
  /// 앱을 완전히 종료해야 풀린다.
  locked,

  /// 그 밖(원인 미상). 메시지를 보여 제보로 확정한다.
  other,
}

const _sqliteBusy = 5;
const _sqliteLocked = 6;
const _sqliteFull = 13;
const _enospc = 28;

/// [error] 를 [DbFailureKind] 로 나눈다. 결과 코드가 없으면 메시지로 본다(번들 SQLite 의 `SqliteException(13): ...` 등).
DbFailureKind classifyDbFailure(Object? error) {
  if (error is DatabaseException) {
    final code = error.getResultCode();
    if (code != null) {
      final primary = code & 0xff;
      if (primary == _sqliteFull) return DbFailureKind.storageFull;
      if (primary == _sqliteBusy || primary == _sqliteLocked) {
        return DbFailureKind.locked;
      }
    }
  }
  if (error is FileSystemException && error.osError?.errorCode == _enospc) {
    return DbFailureKind.storageFull;
  }
  final text = '$error'.toLowerCase();
  if (text.contains('disk is full') ||
      text.contains('no space left') ||
      text.contains('sqlite_full') ||
      text.contains('errno = $_enospc')) {
    return DbFailureKind.storageFull;
  }
  if (text.contains('database is locked') ||
      text.contains('database table is locked') ||
      text.contains('sqlite_busy')) {
    return DbFailureKind.locked;
  }
  return DbFailureKind.other;
}

/// 화면·복사용 한 줄 요약(종류 + 메시지, 최대 [maxLength] 자). 개인정보가 섞일 수 있는 경로는 파일 이름까지만 남긴다.
String describeDbFailure(Object? error, {int maxLength = 400}) {
  var text = '${error.runtimeType}: $error';
  text = text.replaceAllMapped(
    RegExp(r'/data/(?:user/\d+|data)/[^\s/]+/'),
    (_) => '<app>/',
  );
  if (text.length > maxLength) text = '${text.substring(0, maxLength)}…';
  return text;
}
