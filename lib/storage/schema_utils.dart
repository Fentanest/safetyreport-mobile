import 'package:sqflite/sqflite.dart';

/// 열이 없을 때만 추가한다. 예전처럼 모든 ALTER 오류를 삼키면 열 추가가 실패해도 버전만 올라가
/// 이후 저장이 깨진다(저장 계층 재설계 M-15). "이미 있음"만 건너뛰고 다른 오류는 그대로 올린다.
Future<void> addColumnIfMissing(
  DatabaseExecutor db,
  String table,
  String column,
  String typeSql,
) async {
  final rows = await db.rawQuery('PRAGMA table_info("$table")');
  if (rows.any((r) => r['name'] == column)) return;
  await db.execute('ALTER TABLE "$table" ADD COLUMN "$column" $typeSql');
}
