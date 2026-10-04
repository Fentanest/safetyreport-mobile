import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../community/community_store.dart';

/// Connects the personal-file publication and community dataset rotation.
/// This private journal is not part of the server/mobile exchange schema.
class LocalDatabaseExchange {
  static Future<String> _hash(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

  static Future<void> _write(File file, Map<String, Object?> data) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  }

  static Future<void> publish({
    required String destination,
    required String prepared,
    required String reason,
    required CommunityStore store,
    required Future<void> Function(String source, String target) copy,
    required Future<void> Function() commit,
  }) async {
    await recover(destination, store: store);
    final journal = File('$destination.exchange.json');
    final previous = File(destination);
    final operation = newUuidV4();
    final backup = '$destination.exchange-good-$operation.db';
    final hadPrevious = await previous.exists();
    if (hadPrevious) await copy(destination, backup);
    final record = <String, Object?>{
      'format_version': 1,
      'operation_id': operation,
      'stage': 'prepared',
      'previous_good': hadPrevious ? backup : null,
      'previous_sha256': hadPrevious ? await _hash(backup) : null,
      'previous_target_sha256': hadPrevious ? await _hash(destination) : null,
      'prepared_sha256': await _hash(prepared),
      'previous_dataset': await store.localDatasetId(),
      'previous_history': await store.meta('dataset_history') ?? '[]',
      'next_dataset': newUuidV4(),
    };
    await _write(journal, record);
    try {
      await store.deactivateContext('database_exchange');
      record['stage'] = 'publishing';
      await _write(journal, record);
      await store.rotateDataset(
        reason,
        newDatasetId: record['next_dataset'] as String,
      );
      await commit();
      if (await _hash(destination) != record['prepared_sha256']) {
        throw const FormatException('교환 DB 파일 검증 실패');
      }
      record['stage'] = 'published';
      await _write(journal, record);
      if (hadPrevious) await File(backup).delete();
      await journal.delete();
    } catch (_) {
      // If rename succeeded, hash decides which complete file won. If it did
      // not, restore the previous good file and its dataset together.
      await recover(destination, store: store);
      rethrow;
    }
  }

  /// Called before opening the personal DB, after a crash or failed publication.
  /// Unknown formats, damaged backups and unexpected paths fail closed.
  static Future<void> recover(
    String destination, {
    CommunityStore? store,
  }) async {
    final journal = File('$destination.exchange.json');
    if (!await journal.exists()) return;
    final record = jsonDecode(await journal.readAsString());
    if (record is! Map ||
        record['format_version'] != 1 ||
        !['prepared', 'publishing', 'published'].contains(record['stage'])) {
      throw const FormatException('지원하지 않는 DB 교환 복구 기록');
    }
    for (final key in ['operation_id', 'previous_dataset', 'next_dataset']) {
      if (record[key] is! String || (record[key] as String).isEmpty) {
        throw const FormatException('DB 교환 복구 식별자가 없습니다.');
      }
    }
    for (final key in [
      'prepared_sha256',
      'previous_sha256',
      'previous_target_sha256',
    ]) {
      if (record[key] == null && key != 'prepared_sha256') continue;
      if (record[key] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(record[key] as String)) {
        throw const FormatException('DB 교환 복구 해시가 올바르지 않습니다.');
      }
    }
    if (record['previous_history'] is! String ||
        jsonDecode(record['previous_history'] as String) is! List) {
      throw const FormatException('DB 교환 이력 형식이 올바르지 않습니다.');
    }
    final backup = record['previous_good'];
    if (backup != null &&
        (backup is! String ||
            p.dirname(backup) != p.dirname(destination) ||
            !backup.startsWith('$destination.exchange-good-') ||
            !backup.endsWith('.db'))) {
      throw const FormatException('DB 교환 복구 경로가 올바르지 않습니다.');
    }
    final s = store ?? await CommunityStore.open();
    final target = File(destination);
    final exists = await target.exists();
    final targetHash = exists ? await _hash(destination) : null;
    // A durable published marker survives later legitimate writes. Never restore
    // an older file merely because those writes changed its hash.
    if (record['stage'] == 'published' && !exists) {
      throw const FormatException('완료된 교환 DB 파일이 없습니다.');
    }
    final published =
        record['stage'] == 'published' ||
        (exists && targetHash == record['prepared_sha256']);
    if (!published &&
        exists &&
        targetHash != record['previous_target_sha256']) {
      throw const FormatException('교환 이후 변경된 DB를 덮어쓰지 않았습니다.');
    }
    if (published) {
      await s.setMeta('local_dataset_id', record['next_dataset'] as String);
    } else {
      if (backup != null) {
        if (!await File(backup as String).exists() ||
            await _hash(backup) != record['previous_sha256']) {
          throw const FormatException('정상 DB 복구 사본을 확인할 수 없습니다.');
        }
        final recovery = '$destination.exchange-recovery';
        await File(backup).copy(recovery);
        for (final suffix in ['-wal', '-shm', '-journal']) {
          final side = File('$destination$suffix');
          if (await side.exists()) await side.delete();
        }
        await File(recovery).rename(destination);
      } else if (await target.exists()) {
        throw const FormatException('예상하지 못한 DB 파일을 덮어쓰지 않았습니다.');
      }
      await s.transaction((tx) async {
        await s.setMeta(
          'local_dataset_id',
          record['previous_dataset'] as String,
          tx,
        );
        await s.setMeta(
          'dataset_history',
          record['previous_history'] as String,
          tx,
        );
      });
    }
    await s.deactivateContext('database_exchange_recovery');
    if (backup != null && await File(backup as String).exists()) {
      await File(backup).delete();
    }
    await journal.delete();
  }
}
