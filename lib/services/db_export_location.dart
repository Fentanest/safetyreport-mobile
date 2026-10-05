import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/sr_snack_bar.dart';

class SavedDbExport {
  final String uri, filename, location;
  final bool downloads;
  const SavedDbExport({
    required this.uri,
    required this.filename,
    required this.location,
    required this.downloads,
  });
  factory SavedDbExport.fromMap(Map<Object?, Object?> m) => SavedDbExport(
    uri: m['uri'] as String,
    filename: m['filename'] as String,
    location: m['location'] as String,
    downloads: m['downloads'] == true,
  );
  Map<String, Object> get arguments => {
    'uri': uri,
    'filename': filename,
    'location': location,
    'downloads': downloads,
  };
}

class DbExportLocation {
  static const backupLocationHint =
      'Android 10 이상: Download/mysafetyreport/\nAndroid 7~9: 저장할 위치를 직접 선택합니다.';

  static const _channel = MethodChannel(
    'com.fentanest.mysafetyreport/permissions',
  );
  static Future<File> stage(String filename) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/$filename');
  }

  static Future<SavedDbExport?> publish(File source) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'publishDbExport',
      {'path': source.path, 'filename': source.uri.pathSegments.last},
    );
    return result == null ? null : SavedDbExport.fromMap(result);
  }

  static Future<bool> open(
    SavedDbExport saved, {
    String action = 'location',
  }) async {
    try {
      return await _channel.invokeMethod<bool>('openDbExport', {
            ...saved.arguments,
            'action': action,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> notify(SavedDbExport saved) async {
    try {
      await _channel.invokeMethod<void>('notifyDbExport', saved.arguments);
    } on PlatformException {
      /* The saved export stays complete. */
    } on MissingPluginException {
      /* Non-Android test environment. */
    }
  }

  static Future<void> completed(
    BuildContext context,
    SavedDbExport saved,
  ) async {
    final foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!foreground || !context.mounted) {
      await notify(saved);
      return;
    }
    if (!context.mounted) return;
    showSrSnack(
      context,
      'DB 저장 완료\n${saved.filename}\n${saved.location}',
      duration: const Duration(seconds: 15),
      action: SnackBarAction(
        label: '저장 위치 열기',
        onPressed: () => showLocation(context, saved),
      ),
    );
    await showLocation(context, saved);
  }

  static Future<void> showLocation(
    BuildContext context,
    SavedDbExport saved,
  ) async {
    if (await open(saved)) return;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('DB 저장 완료'),
        content: SelectableText(
          '${saved.filename}\n${saved.location}\n파일 앱을 열 수 없습니다. 파일 열기 또는 공유를 이용하세요.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              if (!await open(saved, action: 'file') && ctx.mounted) {
                showSrSnack(
                  ctx,
                  'DB 파일을 처리할 앱이 없습니다.',
                  kind: SrSnackKind.error,
                );
              }
            },
            child: const Text('파일 열기'),
          ),
          TextButton(
            onPressed: () async {
              if (!await open(saved, action: 'share') && ctx.mounted) {
                showSrSnack(ctx, '공유 앱을 열 수 없습니다.', kind: SrSnackKind.error);
              }
            },
            child: const Text('공유'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }
}
