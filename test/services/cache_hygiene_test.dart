// 2026-10-17 제보 대응: 앱 캐시의 남은 스테이징 사본·오래된 첨부만 정리하고, 쓰는 중일 수 있는 것과 앱 밖 파일은 남긴다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/cache_hygiene.dart';

void main() {
  late Directory root;
  final now = DateTime.now();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cache_hygiene_test_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> file(String rel, {required DateTime at, int bytes = 10}) async {
    final f = File('${root.path}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List<int>.filled(bytes, 1));
    await f.setLastModified(at);
    return f;
  }

  Future<void> age(String relDir, DateTime at) async {
    // 폴더 자체의 수정 시각도 과거로 돌린다(파일 생성이 폴더 시각을 지금으로 바꾼다).
    await Process.run('touch', [
      '-m',
      '-d',
      at.toIso8601String(),
      '${root.path}/$relDir',
    ]);
  }

  test('stale staging dirs and files go, fresh ones and others stay', () async {
    final old = now.subtract(const Duration(hours: 7));
    final fresh = now.subtract(const Duration(minutes: 30));
    await file('sr_duplicate_stage_a/projection.db', at: old, bytes: 100);
    await age('sr_duplicate_stage_a', old);
    await file('mysafetyreport_import_staged_b/x.db', at: fresh);
    await age('mysafetyreport_import_staged_b', old);
    await file('backup_data_1.db', at: old, bytes: 50);
    await file('open_1_a.pdf', at: fresh);
    await file('unrelated/keep.txt', at: old);
    await age('unrelated', old);
    await file('share_plus/keep.png', at: old);

    final report = await CacheHygiene.run(roots: [root], now: now);

    expect(
      Directory('${root.path}/sr_duplicate_stage_a').existsSync(),
      isFalse,
    );
    expect(File('${root.path}/backup_data_1.db').existsSync(), isFalse);
    // 안의 파일이 최근이면 쓰는 중일 수 있다.
    expect(
      Directory('${root.path}/mysafetyreport_import_staged_b').existsSync(),
      isTrue,
    );
    expect(File('${root.path}/open_1_a.pdf').existsSync(), isTrue);
    expect(File('${root.path}/unrelated/keep.txt').existsSync(), isTrue);
    expect(File('${root.path}/share_plus/keep.png').existsSync(), isTrue);
    expect(report.deletedEntries, 2);
    expect(report.deletedBytes, 150);
  });

  test(
    'attachments: age limit, stale .part, and size budget oldest first',
    () async {
      final old = now.subtract(const Duration(days: 20));
      await file('attachments/a/ready.json', at: old);
      await file('attachments/a/x.jpg', at: old, bytes: 1000);
      await age('attachments/a', old);
      final week = now.subtract(const Duration(days: 7));
      await file('attachments/b/ready.json', at: week);
      await file('attachments/b/y.jpg', at: week, bytes: 1000);
      await file('attachments/b/z.part', at: week, bytes: 5);
      await age('attachments/b', week);
      final recent = now.subtract(const Duration(minutes: 1));
      await file('attachments/c/c.part', at: recent, bytes: 5);

      final report = await CacheHygiene.run(roots: [root], now: now);

      expect(Directory('${root.path}/attachments/a').existsSync(), isFalse);
      expect(File('${root.path}/attachments/b/y.jpg').existsSync(), isTrue);
      expect(File('${root.path}/attachments/b/z.part').existsSync(), isFalse);
      expect(File('${root.path}/attachments/c/c.part').existsSync(), isTrue);
      expect(report.deletedEntries, 2);
    },
  );

  test('aggressive clears attachments except ones in use', () async {
    final hour = now.subtract(const Duration(hours: 1));
    await file('attachments/b/y.jpg', at: hour, bytes: 1000);
    await age('attachments/b', hour);
    final recent = now.subtract(const Duration(minutes: 1));
    await file('attachments/c/c.part', at: recent, bytes: 5);
    await file('mysafetyreport_pick_x/a.db', at: hour);
    await age('mysafetyreport_pick_x', hour);

    await CacheHygiene.run(roots: [root], now: now, aggressive: true);

    expect(Directory('${root.path}/attachments/b').existsSync(), isFalse);
    expect(File('${root.path}/attachments/c/c.part').existsSync(), isTrue);
    expect(
      Directory('${root.path}/mysafetyreport_pick_x').existsSync(),
      isFalse,
    );
  });

  test('missing root is not an error', () async {
    final report = await CacheHygiene.run(
      roots: [Directory('${root.path}/nope')],
      now: now,
    );
    expect(report.deletedEntries, 0);
  });
}
