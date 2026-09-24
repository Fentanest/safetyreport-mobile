// 공유 DB 연결과 백그라운드 작업 (저장 계층 재설계 R6, M-25).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final throwsBusy = throwsA(isA<DbBusyException>());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = Directory.systemTemp.createTempSync('sr_connection_test_');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalDbService.closeDb();
    await deleteDatabase(await LocalDbService.getDbPath());
  });
  tearDownAll(() async {
    await LocalDbService.closeDb();
    dir.deleteSync(recursive: true);
  });

  test('closeDb waits until background work finishes its writes', () async {
    final gate = Completer<void>();
    final work = LocalDbService.runBackgroundWork(() async {
      await gate.future;
      // 닫기 요청을 본 뒤에도 하던 쓰기는 끝낼 수 있어야 한다
      expect(LocalDbService.closeRequested, isTrue);
      await LocalDbService.setMeta('bg_write', 'done');
    });
    var closed = false;
    final closing = LocalDbService.closeDb().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(closed, isFalse);
    gate.complete();
    await work;
    await closing;
    expect(closed, isTrue);
    expect(LocalDbService.closeRequested, isFalse);
    expect(await LocalDbService.getMeta('bg_write'), 'done'); // 다시 열어 읽힘
  });

  test(
    'backup, restore and server import are refused while background work runs',
    () async {
      final gate = Completer<void>();
      final work = LocalDbService.runBackgroundWork(() => gate.future);
      final target = '${dir.path}/backup.db';
      await expectLater(LocalDbService.exportBackup(target), throwsBusy);
      await expectLater(LocalDbService.replaceFromBackup(target), throwsBusy);
      await expectLater(LocalDbService.importFromServerDb(target), throwsBusy);
      expect(File(target).existsSync(), isFalse);
      gate.complete();
      await work;
      expect(LocalDbService.hasBackgroundWork, isFalse);
    },
  );

  test(
    'closing the connection from inside background work is refused instead of deadlocking',
    () async {
      await expectLater(
        LocalDbService.runBackgroundWork(LocalDbService.closeDb),
        throwsStateError,
      );
      expect(LocalDbService.hasBackgroundWork, isFalse);
    },
  );

  test(
    'while the DB file is being copied or replaced, other callers wait instead of reopening it (G11-4)',
    () async {
      await LocalDbService.setMeta('before', '1');
      var opened = false;
      var startedWork = false;
      await LocalDbService.withFileExclusiveForTest(() async {
        // 파일 작업 밖(다른 화면·스케줄러)에서 들어온 호출
        Zone.root.run(() {
          LocalDbService.db.then((_) => opened = true);
          LocalDbService.runBackgroundWork(() async => startedWork = true);
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect((opened, startedWork), (false, false));
        await LocalDbService.getMeta('before'); // 파일 작업 자신은 통과
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((opened, startedWork), (true, true));
      expect(await LocalDbService.getMeta('before'), '1');
    },
  );
}
