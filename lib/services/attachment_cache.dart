import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class AttachmentCancelled implements Exception {}

/// A private, scope-bound cache. A completed file is published only after the
/// entire response arrived; a matching filename is never a cache identity.
class AttachmentCache {
  static Future<File> fetch({
    required Directory root,
    required Uri uri,
    required String scope,
    Map<String, String>? headers,
    required bool Function() isCancelled,
    http.Client Function()? clientFactory,
    Duration deadline = const Duration(seconds: 30),
    void Function(int status)? onStatus,
  }) async {
    final key = sha256.convert(utf8.encode('$scope\u0000$uri')).toString();
    final folder = Directory(p.join(root.path, 'attachments', key));
    await folder.create(recursive: true);
    final extension = p.extension(uri.path);
    final safeExtension = RegExp(r'^\.[a-zA-Z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.bin';
    final metadata = File(p.join(folder.path, 'ready.json'));
    final operation = List.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final part = File(p.join(folder.path, '$operation.part'));
    final metaPart = File('${metadata.path}.$operation.part');
    Map<String, dynamic>? previous;
    File? previousFile;
    try {
      if (await metadata.exists()) {
        final raw =
            jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
        if (raw['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['sha256'] as String)) {
          throw const FormatException('캐시 식별자 오류');
        }
        final ready = File(
          p.join(folder.path, '${raw['sha256']}$safeExtension'),
        );
        final digest = (await sha256.bind(ready.openRead()).first).toString();
        if (raw['bytes'] == await ready.length() && raw['sha256'] == digest) {
          previous = raw;
          previousFile = ready;
        }
      }
    } catch (_) {
      previous = null;
    }
    final client = (clientFactory ?? http.Client.new)();
    var expired = false;
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
      client.close();
    }

    final timer = Timer(deadline, () {
      expired = true;
      cancel();
    });
    final poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (isCancelled()) cancel();
    });
    IOSink? output;
    final elapsed = Stopwatch()..start();
    try {
      if (isCancelled()) throw AttachmentCancelled();
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      );
      request.headers.addAll(headers ?? const {});
      if (previous?['etag'] is String) {
        request.headers['If-None-Match'] = previous!['etag'] as String;
      }
      if (previous?['modified'] is String) {
        request.headers['If-Modified-Since'] = previous!['modified'] as String;
      }
      final response = await client.send(request).timeout(deadline);
      onStatus?.call(response.statusCode);
      if (response.statusCode == 304 && previous != null) {
        await response.stream.drain<void>();
        if (expired || isCancelled()) throw AttachmentCancelled();
        return previousFile!;
      }
      if (response.statusCode != 200) {
        throw HttpException('첨부 다운로드 실패: ${response.statusCode}');
      }
      output = part.openWrite();
      var bytes = 0;
      var bufferedBytes = 0;
      final iterator = StreamIterator(response.stream);
      try {
        while (true) {
          final remaining = deadline - elapsed.elapsed;
          if (remaining <= Duration.zero) {
            throw TimeoutException('첨부 다운로드 시간 초과');
          }
          if (!await iterator.moveNext().timeout(remaining)) break;
          if (expired || isCancelled()) throw AttachmentCancelled();
          output.add(iterator.current);
          bytes += iterator.current.length;
          bufferedBytes += iterator.current.length;
          if (bufferedBytes >= 256 * 1024) {
            await output.flush().timeout(deadline - elapsed.elapsed);
            bufferedBytes = 0;
          }
        }
      } finally {
        await iterator.cancel();
      }
      await output.flush();
      await output.close();
      output = null;
      if (expired || isCancelled()) throw AttachmentCancelled();
      if (response.contentLength != null && bytes != response.contentLength) {
        throw const FormatException('첨부 길이가 일치하지 않습니다.');
      }
      final digest = (await sha256.bind(part.openRead()).first).toString();
      if (expired || isCancelled()) throw AttachmentCancelled();
      // Each caller returns an immutable content file. Concurrent responses may
      // replace the metadata pointer, but cannot overwrite another caller's bytes.
      final ready = File(p.join(folder.path, '$digest$safeExtension'));
      await part.rename(ready.path);
      await metaPart.writeAsString(
        jsonEncode({
          'bytes': bytes,
          'sha256': digest,
          'etag': response.headers['etag'],
          'modified': response.headers['last-modified'],
        }),
        flush: true,
      );
      await metaPart.rename(metadata.path);
      return ready;
    } finally {
      timer.cancel();
      poll.cancel();
      client.close();
      await output?.close();
      if (await part.exists()) await part.delete();
      if (await metaPart.exists()) await metaPart.delete();
    }
  }
}
