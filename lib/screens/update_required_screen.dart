import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../community/update_requirement.dart';

/// 필수 버전 잠금 화면(CLIENT-RULES 6절·11절 문구). 로컬 자료는 지우지 않는다.
///
/// 업데이트 버튼: Play 설치본이면 Play In-App Updates **즉시 업데이트**를 먼저 시도하고, 안 되면 서버가 준
/// `url.mobile`(없으면 Play 스토어). GitHub APK 설치본은 GitHub 릴리스 주소를 연다.
class UpdateRequiredScreen extends StatefulWidget {
  const UpdateRequiredScreen({super.key, required this.requirement});

  final UpdateRequirement requirement;

  /// 시험용 주입: 설치 출처(`com.android.vending` 이면 Play).
  @visibleForTesting
  static Future<String?> Function()? installerForTest;

  /// 시험용 주입: 즉시 업데이트 시도(성공하면 true).
  @visibleForTesting
  static Future<bool> Function()? immediateUpdateForTest;

  /// 시험용 주입: 주소 열기.
  @visibleForTesting
  static Future<bool> Function(Uri uri)? launcherForTest;

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

const _playInstaller = 'com.android.vending';

/// 업데이트 주소 고르기(시험 가능하게 뺀 순수 함수).
Uri updateTarget(UpdateRequirement requirement, String? installer) {
  if (installer != null && installer.isNotEmpty && installer != _playInstaller) {
    return Uri.parse(githubReleaseUrl);
  }
  final server = requirement.url;
  final parsed = server == null ? null : Uri.tryParse(server);
  if (parsed != null && parsed.scheme == 'https') return parsed;
  return Uri.parse(playStoreUrl);
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  bool _busy = false;
  String? _error;

  Future<String?> _installer() async {
    final injected = UpdateRequiredScreen.installerForTest;
    if (injected != null) return injected();
    try {
      return (await PackageInfo.fromPlatform()).installerStore;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _immediateUpdate() async {
    final injected = UpdateRequiredScreen.immediateUpdateForTest;
    if (injected != null) return injected();
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability != UpdateAvailability.updateAvailable ||
          !info.immediateUpdateAllowed) {
        return false;
      }
      return await InAppUpdate.performImmediateUpdate() ==
          AppUpdateResult.success;
    } catch (_) {
      return false;
    }
  }

  Future<void> _update() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final installer = await _installer();
      final fromPlay =
          installer == null || installer.isEmpty || installer == _playInstaller;
      if (fromPlay && await _immediateUpdate()) return;
      final uri = updateTarget(widget.requirement, installer);
      final launcher =
          UpdateRequiredScreen.launcherForTest ??
          (u) => launchUrl(u, mode: LaunchMode.externalApplication);
      if (!await launcher(uri) && mounted) {
        setState(() => _error = '업데이트 화면을 열지 못했습니다. 잠시 뒤 다시 눌러 주세요.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '업데이트 화면을 열지 못했습니다. 잠시 뒤 다시 눌러 주세요.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final req = widget.requirement;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) SystemNavigator.pop();
      },
      child: Scaffold(
        key: const Key('updateRequiredScreen'),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.system_update,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '앱을 업데이트해 주세요',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '이 버전은 더 이상 신고를 공유할 수 없습니다. 최신 버전으로 업데이트하면 이어서 쓸 수 있습니다. '
                    '기기에 있는 신고 자료는 그대로 남아 있습니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(height: 1.5),
                  ),
                  if (req.minVersion != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      '필요한 버전: ${req.minVersion} 이상',
                      key: const Key('updateRequiredVersion'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                  if (req.message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      req.message!,
                      key: const Key('updateRequiredMessage'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('updateRequiredButton'),
                    onPressed: _busy ? null : _update,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('업데이트'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
