import 'package:sqflite/sqflite.dart';

/// Synthetic and deterministic. Never calls a crawler, rating service or upload.
/// Intended for a fresh test database or the isolated profile probe's demo DB.
Future<void> seedLargeDataFixture(
  Database db,
  int count, {
  bool giantRawGroups = false,
}) async {
  if (count < 0) throw ArgumentError.value(count);
  await db.transaction((t) async {
    for (final table in [
      'duplicate_member',
      'duplicate_group',
      'duplicate_decision',
      'report_override',
      'report_raw',
      'reports',
    ]) {
      await t.delete(table);
    }
  });
  for (var start = 0; start < count; start += 1000) {
    final end = (start + 1000).clamp(0, count);
    await db.transaction((t) async {
      await t.rawInsert(
        '''
        WITH RECURSIVE n(i) AS (SELECT ? UNION ALL SELECT i+1 FROM n WHERE i+1 < ?)
        INSERT INTO reports(ID, 신고번호, category, 신고명, 처리상태, 신고일, 답변일,
          처리기관, 처리기관코드, 담당자, 범칙금_과태료, 차량번호, 위반법규, entry_value,
          별점, 위반장소, 위도, 경도, synced_at, 신고내용, 처리내용, 보완횟수, 종결여부, 감시목록)
        SELECT printf('fixture-%09d',i), printf('SPP-%09d',i),
          CASE i%3 WHEN 0 THEN 'traffic' WHEN 1 THEN 'parking' ELSE 'other' END,
          CASE i%5 WHEN 0 THEN '버스전용차로 위반' ELSE '합성 신고 ' || (i%17) END,
          CASE i%9 WHEN 0 THEN '수용' WHEN 1 THEN '일부수용' WHEN 2 THEN '불수용' WHEN 3 THEN '답변완료'
            WHEN 4 THEN '취하' WHEN 5 THEN '처리중' WHEN 6 THEN '보완요청' WHEN 7 THEN NULL ELSE '기타' END,
          CASE WHEN i%53=0 THEN '2026-02-30' ELSE printf('%04d-%02d-%02d',2020+i%7,1+i%12,1+i%25) END,
          CASE WHEN i%9 IN (5,6,7) THEN NULL ELSE printf('%04d-%02d-%02d',2020+i%7,1+i%12,3+i%25) END,
          CASE WHEN i%41=0 THEN NULL WHEN i%2=0 THEN '예시경찰서 ' || (i%40) ELSE '예시 시청 ' || (i%40) END,
          CASE i%43 WHEN 0 THEN '1324107' ELSE NULL END,
          CASE WHEN i%37=0 THEN '미지정' ELSE '담당자 ' || (i%200) END,
          CASE i%7 WHEN 0 THEN '과태료 40,000원' WHEN 1 THEN '과태료' WHEN 2 THEN '경고'
            WHEN 3 THEN '범칙금 30,000원' WHEN 4 THEN '미확인' WHEN 5 THEN NULL ELSE '' END,
          printf('12가%04d',i%10000), CASE WHEN i%13=0 THEN NULL ELSE '도로교통법 제' || (i%20) || '조' END,
          CASE i%3 WHEN 0 THEN '자동차·교통위반' WHEN 1 THEN '불법주정차신고' ELSE '쓰레기, 폐기물' END,
          CASE WHEN i%11=0 THEN NULL ELSE 1+i%5 END,
          '합성 주소 ' || (i%30000),
          CASE WHEN i%19=0 THEN NULL ELSE 33.0+(i%6000)/1000.0 END,
          CASE WHEN i%19=0 THEN NULL ELSE 125.0+(i%5000)/1000.0 END,
          i, CASE WHEN i%11=0 THEN '합성 긴 본문\n' || hex(zeroblob(1024)) ELSE '합성 본문' END,
          '합성 답변\nNULL·빈값·결과 미상', i%4, 'Y', CASE WHEN i%97=0 THEN 'Y' ELSE 'N' END
        FROM n
      ''',
        [start, end],
      );
      await t.rawInsert(
        '''INSERT INTO report_raw(ID,raw_content,raw_type,saved_at)
        SELECT ID,
          ${giantRawGroups ? "CASE WHEN CAST(substr(ID,9) AS INTEGER)%13=0 THEN hex(zeroblob(4096)) ELSE '합성 원문' END" : "'합성 원문 ' || printf('%09d',CASE WHEN CAST(substr(ID,9) AS INTEGER)%250<2 THEN (CAST(substr(ID,9) AS INTEGER)/250)*250 ELSE CAST(substr(ID,9) AS INTEGER) END) || CASE WHEN (CASE WHEN CAST(substr(ID,9) AS INTEGER)%250<2 THEN (CAST(substr(ID,9) AS INTEGER)/250)*250 ELSE CAST(substr(ID,9) AS INTEGER) END)%13=0 THEN char(10)||hex(zeroblob(4096)) ELSE '' END"},
        'report_body', 0 FROM reports WHERE ID >= ? AND ID < ?''',
        [
          'fixture-${start.toString().padLeft(9, '0')}',
          'fixture-${end.toString().padLeft(9, '0')}',
        ],
      );
    });
  }
  // Confirmed/review-required groups, raw group membership preserved; no original
  // text is loaded to rediscover groups merely to show dashboard/statistics.
  await db.rawInsert(
    '''INSERT INTO duplicate_group(group_id,fingerprint,match_type,status,representative_mode,representative_id,member_count)
    SELECT 'g-'||ID, ID, 'payload_exact', CASE WHEN CAST(substr(ID,9) AS INTEGER)%500=0 THEN 'confirmed_duplicate' ELSE 'review_required' END,
      'auto', ID, 2 FROM reports WHERE CAST(substr(ID,9) AS INTEGER)%250=0 AND CAST(substr(ID,9) AS INTEGER)+1 < ?''',
    [count],
  );
  await db.rawInsert(
    '''INSERT INTO duplicate_member(group_id,report_id,report_number,category,is_representative)
    SELECT g.group_id, r.ID, r.신고번호, r.category, CASE WHEN r.ID=g.representative_id THEN 1 ELSE 0 END
    FROM duplicate_group g JOIN reports r ON r.ID=g.representative_id OR r.ID=printf('fixture-%09d',CAST(substr(g.representative_id,9) AS INTEGER)+1)''',
  );
}
