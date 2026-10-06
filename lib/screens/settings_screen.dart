import '../services/db_export_location.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../models/app_mode.dart';
import '../models/app_theme_mode.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/app_storage_paths.dart';
import '../services/local_db_service.dart';
import '../widgets/official_account_reset_dialog.dart';
import '../services/pending_db_import_action.dart';
import '../services/permission_service.dart';
import '../services/server_connection_service.dart';
import '../services/server_contract.dart';
import '../services/standalone_auth_service.dart';
import '../services/review_prompt_service.dart';
import '../services/support_links.dart';
import 'permission_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import '../navigation/app_routes.dart';
import '../widgets/auth_status_notice.dart';
import '../community/client_account_notice.dart';
import '../community/gate/community_gate.dart';
import '../widgets/community_account_card.dart';
import '../widgets/community_server_account_card.dart';
import '../widgets/dispose_on_unmount.dart';
import '../widgets/mode_badge.dart';
import '../widgets/sr_page_padding.dart';
import '../server_palette.dart';
import '../widgets/status_badge.dart';
import '../theme/sr_colors.dart';
import '../theme/sr_tokens.dart';
import '../widgets/sr_snack_bar.dart';

const _officialSafetyReportUrl = 'https://www.safetyreport.go.kr/';

class SettingsScreen extends StatefulWidget {
  /// 대시보드 '재로그인 필요' 경고에서 열 때 true — 화면이 뜨면 바로 재로그인 창을 연다(Standalone).
  final bool openReloginOnStart;

  const SettingsScreen({super.key, this.openReloginOnStart = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlController = TextEditingController();
  final _apiController = TextEditingController();
  bool _obscureKey = true;
  bool _testing = false;

  /// "저장" 진행 중(연결 확인 → setConfig). 두 번 실행·연결 테스트와 겹침을 막는다(SQ-B08).
  bool _saving = false;
  _TestResult? _testResult;
  bool _wsRunning = false;
  bool _wsToggling = false;
  bool _isBackingUpDb = false;

  /// Client DB 백업 다운로드 진행(받은 바이트, 전체 — 모르면 null)과 취소. 받는 중이 아니면 null.
  final ValueNotifier<(int, int?)> _dbDownloadProgress = ValueNotifier((
    0,
    null,
  ));
  DownloadCancel? _dbDownloadCancel;
  bool _isRestoringDb = false;

  // 기타 데이터 필터 세팅
  bool _excludeWithdraw = true;
  bool _useRepresentativeRecords = true;
  bool _autoExportExcel = true;
  bool _autoExportSheet = false;
  bool _filterLoading = false;

  // 앱 버전
  String _appVersion = '';

  // 서버 버전
  String? _serverVersion;
  String? _serverVersionStatus; // up_to_date / outdated / unknown
  String? _serverVersionLatest;
  bool _serverVersionLoading = false;

  @override
  void initState() {
    super.initState();
    final provider = context.read<ReportProvider>();
    _urlController.text = provider.baseUrl;
    _apiController.text = provider.apiKey;
    _checkWsStatus();
    _loadFilterSettings();
    _loadServerVersion();
    _loadPreviousImportBackup();
    // 모드·데모 DB 가 바뀌면 되돌리기 사본 표시도 그 DB 기준으로 다시 읽는다(감사 R2-03).
    _dbKeyProvider = provider..addListener(_onDbTargetMaybeChanged);
    _dbKey = _dbKeyOf(provider);
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = info.version);
    });
    if (widget.openReloginOnStart && provider.appMode == AppMode.standalone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showReloginDialog();
      });
    }
  }

  Future<void> _loadServerVersion() async {
    final p = context.read<ReportProvider>();
    if (p.baseUrl.isEmpty) return;
    setState(() => _serverVersionLoading = true);
    try {
      final info = await ServerConnectionService.fetchVersionInfo(
        baseUrl: p.baseUrl,
        apiKey: p.apiKey,
      );
      if (!mounted) return;
      setState(() {
        _serverVersion = info.version;
        _serverVersionStatus = info.status;
        _serverVersionLatest = info.latestVersion;
      });
    } finally {
      if (mounted) setState(() => _serverVersionLoading = false);
    }
  }

  ApiService? _buildApi() {
    final p = context.read<ReportProvider>();
    if (p.baseUrl.isEmpty) return null;
    return ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
  }

  Future<void> _loadFilterSettings() async {
    final p = context.read<ReportProvider>();
    // standalone 모드: SharedPreferences 기반 필터값 로드 (provider가 보유)
    if (p.appMode == AppMode.standalone) {
      if (mounted) {
        setState(() {
          _excludeWithdraw = p.excludeWithdraw;
          _useRepresentativeRecords = p.useRepresentativeRecords;
          // 자동 Excel/Sheet 내보내기는 서버 기능이므로 standalone에서는 비활성
          _autoExportExcel = false;
          _autoExportSheet = false;
        });
      }
      return;
    }
    final api = _buildApi();
    if (api == null) return;
    try {
      final cfg = await api.getAppConfig();
      if (mounted) {
        setState(() {
          _excludeWithdraw = cfg['exclude_withdraw'] as bool? ?? true;
          _useRepresentativeRecords =
              cfg['use_representative_records'] as bool? ?? true;
          _autoExportExcel = cfg['auto_export_excel'] as bool? ?? true;
          _autoExportSheet = cfg['auto_export_sheet'] as bool? ?? false;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleFilter(String key, bool value) async {
    setState(() => _filterLoading = true);
    final p = context.read<ReportProvider>();
    if (p.appMode == AppMode.standalone) {
      if (key == 'exclude_withdraw') {
        await p.setStandaloneFilter(excludeWithdraw: value);
      } else if (key == 'use_representative_records') {
        await p.setStandaloneFilter(useRepresentativeRecords: value);
      }
      // auto_export_excel/auto_export_sheet 은 standalone 무관
    } else {
      final api = _buildApi();
      if (api != null) {
        try {
          await api.updateSettings({key: value});
          if (mounted) context.read<ReportProvider>().refreshAll();
        } catch (_) {}
      }
    }
    if (mounted) setState(() => _filterLoading = false);
  }

  Future<void> _checkWsStatus() async {
    final running = await PermissionService.isWsServiceRunning();
    if (mounted) setState(() => _wsRunning = running);
  }

  Future<void> _toggleWsService() async {
    setState(() => _wsToggling = true);
    if (_wsRunning) {
      await PermissionService.stopWsService();
    } else {
      await PermissionService.startWsService();
    }
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    await _checkWsStatus();
    if (!mounted) return;
    setState(() => _wsToggling = false);
  }

  ReportProvider? _dbKeyProvider;
  String? _dbKey;

  static String _dbKeyOf(ReportProvider p) =>
      '${p.appMode.name}|${p.isStandaloneDemo}';

  void _onDbTargetMaybeChanged() {
    final p = _dbKeyProvider;
    if (p == null) return;
    final key = _dbKeyOf(p);
    if (key == _dbKey) return;
    _dbKey = key;
    _loadPreviousImportBackup();
  }

  @override
  void dispose() {
    _dbDownloadCancel?.cancel();
    _dbDownloadProgress.dispose();
    _dbKeyProvider?.removeListener(_onDbTargetMaybeChanged);
    _urlController.dispose();
    _apiController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (_testing || _saving) return;
    final url = _urlController.text.trim();
    final key = _apiController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() {
        _testResult = _TestResult.error('URL과 API 키를 모두 입력해주세요.');
      });
      return;
    }

    setState(() {
      _testing = true;
      _testResult = null;
    });

    final cleanUrl = ServerContract.normalizeBaseUrl(url);

    try {
      final compatibility = await ServerConnectionService.checkVersion(
        baseUrl: cleanUrl,
        apiKey: key,
      );
      if (!mounted) return;
      if (!compatibility.isOk) {
        setState(
          () => _testResult = _TestResult.error(
            compatibility.message ?? 'PC 서버 버전을 확인할 수 없습니다.',
          ),
        );
        return;
      }
      final response = await http
          .get(
            ServerContract.apiUri(cleanUrl, ServerContract.summaryPath),
            headers: ServerContract.apiHeaders(key),
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;

      final status = response.statusCode;
      String body = response.body;
      if (body.length > 300) body = '${body.substring(0, 300)}...';

      if (status == 200) {
        try {
          final json = jsonDecode(response.body);
          final total = json['data']?['total'] ?? '?';
          setState(() {
            _testResult = _TestResult.success('연결 성공! 총 $total건 조회됨');
          });
        } catch (_) {
          setState(() {
            _testResult = _TestResult.warn(
              '상태 $status 응답 수신, JSON 파싱 실패\n응답: $body',
            );
          });
        }
      } else if (status == 401) {
        setState(() {
          _testResult = _TestResult.error(
            'API 키 인증 실패 (401)\nAPI 키를 확인해주세요.\n응답: $body',
          );
        });
      } else if (status == 302 || (status == 200 && body.contains('<html'))) {
        setState(() {
          _testResult = _TestResult.error(
            '로그인 페이지로 리다이렉트됨 ($status)\n서버의 /api/v1/ 경로가 세션 인증을 우회하도록 설정되어 있는지 확인하세요.\n응답: $body',
          );
        });
      } else {
        setState(() {
          _testResult = _TestResult.warn('예상치 못한 응답: $status\n$body');
        });
      }
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _testResult = _TestResult.error('연결 실패: $e');
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _testing) return;
    final url = _urlController.text.trim();
    final key = _apiController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      showSrSnack(context, '모든 필드를 입력해주세요.');
      return;
    }
    setState(() {
      _saving = true;
      _testing = true;
    });
    try {
      ServerConnectionResult result;
      try {
        result = await ServerConnectionService.testConnection(
          baseUrl: url,
          apiKey: key,
        );
      } catch (e) {
        if (mounted) {
          setState(() => _testResult = _TestResult.error('서버에 연결할 수 없습니다: $e'));
        }
        return;
      } finally {
        if (mounted) setState(() => _testing = false);
      }
      if (!mounted) return;
      if (!result.isOk) {
        setState(
          () => _testResult = _TestResult.error(
            result.message ?? '서버에 연결할 수 없습니다.',
          ),
        );
        return;
      }
      final provider = context.read<ReportProvider>();
      await provider.setConfig(result.normalizedUrl, key);
      // 설정 변경 후 모든 데이터 새로고침(서버 기능 목록 포함 — setConfig 가 이전 서버 것을 비웠다)
      unawaited(provider.refreshAll());
      if (mounted) {
        showSrSnack(
          context,
          '설정이 저장되었습니다. 데이터를 불러오는 중...',
          kind: SrSnackKind.success,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── 스탠드어론 재로그인 다이얼로그 ─────────────────────────────
  Future<void> _showReloginDialog() async {
    final provider = context.read<ReportProvider>();
    final usernameCtrl = TextEditingController(
      text: provider.standaloneUsername,
    );
    final passwordCtrl = TextEditingController();
    final phoneCtrl = TextEditingController(
      text: provider.standalonePhoneNumber,
    );
    bool obscurePw = true;
    bool loggingIn = false;
    String? err;

    await showDialog(
      context: context,
      barrierDismissible: false,
      // 창이 완전히 닫힌 뒤 컨트롤러를 해제한다. 비밀번호는 먼저 지운다(SQ-B14).
      builder: (ctx) => DisposeOnUnmount(
        onDispose: () {
          passwordCtrl.clear();
          usernameCtrl.dispose();
          passwordCtrl.dispose();
          phoneCtrl.dispose();
        },
        child: StatefulBuilder(
          builder: (ctx, setDlg) => AlertDialog(
            title: const Text('안전신문고 재로그인'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: usernameCtrl,
                  decoration: const InputDecoration(
                    labelText: '아이디',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordCtrl,
                  decoration: InputDecoration(
                    labelText: '비밀번호',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscurePw ? Icons.visibility_off : Icons.visibility,
                        size: 20,
                      ),
                      tooltip: obscurePw ? '비밀번호 보기' : '비밀번호 숨기기',
                      onPressed: () => setDlg(() => obscurePw = !obscurePw),
                    ),
                  ),
                  obscureText: obscurePw,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  decoration: const InputDecoration(
                    labelText: '휴대폰번호',
                    helperText: '별점 사유 조회에 사용됩니다.',
                    helperMaxLines: 2,
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  keyboardType: TextInputType.phone,
                  autocorrect: false,
                ),
                if (err != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    err!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: loggingIn ? null : () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: loggingIn
                    ? null
                    : () async {
                        setDlg(() {
                          loggingIn = true;
                          err = null;
                        });
                        try {
                          final username = usernameCtrl.text.trim();
                          final rawPhone = phoneCtrl.text.trim();
                          final phone = rawPhone.replaceAll(
                            RegExp(r'[^0-9]'),
                            '',
                          );
                          final isDemoLogin =
                              LocalDbService.isPlayReviewDemoLogin(
                                username: username,
                                password: passwordCtrl.text,
                                rawPhone: rawPhone,
                              );
                          if (!isDemoLogin && phone.isEmpty) {
                            throw Exception('휴대폰번호를 입력해주세요.');
                          }
                          if (isDemoLogin) {
                            await LocalDbService.seedPlayReviewDemo();
                          } else {
                            await StandaloneAuthService.login(
                              username,
                              passwordCtrl.text,
                            );
                          }
                          if (ctx.mounted) {
                            await ctx
                                .read<ReportProvider>()
                                .setStandaloneConfig(
                                  username,
                                  phoneNumber: isDemoLogin
                                      ? (rawPhone.isEmpty
                                            ? LocalDbService.playReviewDemoPhone
                                            : rawPhone)
                                      : phone,
                                  isDemoMode: isDemoLogin,
                                  confirmAccountReset: () =>
                                      confirmOfficialAccountReset(ctx),
                                );
                            if (!ctx.mounted || !mounted) return;
                            Navigator.pop(ctx);
                            showSrSnack(
                              context,
                              isDemoLogin ? '데모 모드 전환 완료' : '재로그인 완료',
                              kind: SrSnackKind.success,
                            );
                          }
                        } catch (e) {
                          if (!ctx.mounted) return;
                          setDlg(() {
                            err = e.toString().replaceFirst('Exception: ', '');
                            loggingIn = false;
                          });
                        }
                      },
                child: loggingIn
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(ctx).colorScheme.onPrimary,
                        ),
                      )
                    : const Text('로그인'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _backupDb() async {
    if (_isBackingUpDb) return;
    setState(() => _isBackingUpDb = true);

    File? staged;
    try {
      if (!mounted) return;
      final p = context.read<ReportProvider>();
      final isStandalone = p.appMode == AppMode.standalone;

      final fileName =
          'backup_data_${DateTime.now().millisecondsSinceEpoch}.db';
      final targetFile = await DbExportLocation.stage(fileName);
      staged = targetFile;

      if (isStandalone) {
        await LocalDbService.exportBackup(targetFile.path);
      } else {
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        // 화면이 닫혔으면 받지 않는다(dispose 가 취소할 수 없는 다운로드가 남는다).
        if (!mounted) return;
        final cancel = DownloadCancel();
        _dbDownloadProgress.value = (0, null);
        setState(() => _dbDownloadCancel = cancel);
        await api.downloadDbToFile(
          targetFile.path,
          cancel: cancel,
          onProgress: (received, total) {
            if (mounted) _dbDownloadProgress.value = (received, total);
          },
        );
      }

      final saved = await DbExportLocation.publish(targetFile);
      if (saved != null) {
        if (mounted) {
          await DbExportLocation.completed(context, saved);
        } else {
          await DbExportLocation.notify(saved);
        }
      }
      if (saved == null && mounted) {
        showSrSnack(context, 'DB 저장을 취소했습니다.');
      }
    } on DownloadCancelled {
      if (mounted) {
        showSrSnack(context, 'DB 백업을 취소했습니다.');
      }
    } catch (e) {
      if (mounted) {
        showSrSnack(context, 'DB 백업 실패: $e', kind: SrSnackKind.error);
      }
    } finally {
      if (staged != null && await staged.exists()) await staged.delete();
      _dbDownloadCancel = null;
      if (mounted) setState(() => _isBackingUpDb = false);
    }
  }

  bool _isPrimaryDbFileName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.db') &&
        !lower.endsWith('.db-wal') &&
        !lower.endsWith('.db-shm');
  }

  Future<String?> _stagePickedDbFiles(FilePickerResult result) async {
    final files = result.files.where((file) => file.path != null).toList();
    if (files.isEmpty) return null;

    PlatformFile? mainDb;
    for (final file in files) {
      if (_isPrimaryDbFileName(file.name)) {
        mainDb = file;
        break;
      }
    }
    if (mainDb == null || mainDb.path == null) {
      throw Exception('.db 본파일을 함께 선택해주세요.');
    }

    final stageDir = await Directory.systemTemp.createTemp(
      'mysafetyreport_pick_',
    );
    final stagedDbPath = '${stageDir.path}/${mainDb.name}';
    await File(mainDb.path!).copy(stagedDbPath);

    final walName = '${mainDb.name}-wal'.toLowerCase();
    final shmName = '${mainDb.name}-shm'.toLowerCase();

    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      final lowerName = file.name.toLowerCase();
      if (lowerName == walName) {
        await File(path).copy('$stagedDbPath-wal');
      } else if (lowerName == shmName) {
        await File(path).copy('$stagedDbPath-shm');
      }
    }

    return stagedDbPath;
  }

  /// 가져오기·복원 직전 사본(단독 모드, 없으면 null — 되돌리기 버튼 표시용, 감사 SOL-05).
  String? _previousImportBackup;

  Future<void> _loadPreviousImportBackup() async {
    try {
      final path = await LocalDbService.latestImportBackup();
      if (mounted) setState(() => _previousImportBackup = path);
    } catch (_) {}
  }

  Future<void> _revertToPreviousDb() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('직전 DB 로 되돌리기'),
        content: const Text(
          '마지막 가져오기·복원 직전의 DB 로 되돌립니다.\n'
          '지금 DB 도 사본으로 남기므로 다시 되돌릴 수 있습니다.\n계속하시겠습니까?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('되돌리기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isRestoringDb = true);
    try {
      final done = await LocalDbService.revertToPreviousImport();
      if (!mounted) return;
      await context.read<ReportProvider>().refreshAll();
      if (!mounted) return;
      showSrSnack(
        context,
        done ? '직전 DB 로 되돌렸습니다.' : '되돌릴 사본이 없습니다.',
        kind: done ? SrSnackKind.success : SrSnackKind.error,
      );
    } catch (e) {
      if (mounted) {
        showSrSnack(context, '되돌리기 실패: $e', kind: SrSnackKind.error);
      }
    } finally {
      if (mounted) setState(() => _isRestoringDb = false);
      await _loadPreviousImportBackup();
    }
  }

  Future<void> _restoreDb() async {
    final p = context.read<ReportProvider>();
    final isStandalone = p.appMode == AppMode.standalone;

    if (_isRestoringDb) return;

    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );

    if (result == null) return;

    final dialogMsg = isStandalone
        ? '선택한 .db 파일 형식을 자동 감지합니다.\n'
              '모바일 백업이면 그대로 복원하고, 서버 DB면 standalone 형식으로 변환합니다.\n'
              '같은 폴더에 -wal/-shm 파일이 있으면 함께 반영합니다.\n'
              '계속하시겠습니까?'
        : '서버의 DB가 선택한 파일로 교체됩니다. (서버 형식·모바일 형식 모두 자동 감지)\n'
              '서버는 기존 DB를 자동 백업합니다.\n계속하시겠습니까?';

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('DB 복원'),
        content: Text(dialogMsg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('복원 시작'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isRestoringDb = true);

    try {
      final selectedPath = await _stagePickedDbFiles(result);
      if (selectedPath == null || selectedPath.isEmpty) return;

      if (isStandalone) {
        final kind = await LocalDbService.detectDbKind(selectedPath);
        if (kind == 'server') {
          await LocalDbService.importFromServerDb(selectedPath);
        } else if (kind == 'mobile') {
          await LocalDbService.replaceFromBackup(selectedPath);
        } else {
          throw Exception(
            '알 수 없는 DB 형식입니다. 서버 DB 또는 모바일 백업 .db 파일만 사용할 수 있습니다.',
          );
        }

        if (mounted) {
          await context.read<ReportProvider>().refreshAll();
          if (!mounted) return;
          showSrSnack(
            context,
            kind == 'server'
                ? '서버 DB 변환 복원이 완료되었습니다.'
                : '모바일 백업 복원이 완료되었습니다.',
            kind: SrSnackKind.success,
          );
        }
      } else {
        // Client: 서버에 업로드 → 서버가 자동 감지/변환
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        final res = await api.uploadDb(selectedPath);
        if (mounted) {
          final kind = res['kind'] as String? ?? '';
          final imported = res['imported'];
          showSrSnack(
            context,
            '서버 DB 복원 완료 (${kind == 'mobile' ? '모바일→서버 변환' : '서버 형식'}, $imported건)',
            kind: SrSnackKind.success,
          );
        }
      }
      return; // 아래 standalone 전용 블록 스킵
    } catch (e) {
      if (mounted) {
        showSrSnack(context, 'DB 복원 실패: $e', kind: SrSnackKind.error);
      }
    } finally {
      if (mounted) setState(() => _isRestoringDb = false);
      await _loadPreviousImportBackup();
    }
  }

  // ── 모드 변경 ─────────────────────────────────────────────────
  // Standalone → Client: 현재 모바일 DB 자동 백업 후 reset.
  // Client → Standalone: 3-way 선택 (서버 DB 변환 / 백업 파일 선택 / 처음부터).

  /// Documents/mysafetyreport (없으면 Download/mysafetyreport) 디렉토리 보장.
  static Directory _backupDir() => AppStoragePaths.exportsRoot();

  Future<void> _confirmModeReset() async {
    final p = context.read<ReportProvider>();
    final isStandalone = p.appMode == AppMode.standalone;
    if (isStandalone) {
      await _confirmStandaloneToServer();
    } else {
      await _confirmServerToStandalone();
    }
  }

  /// Standalone → Client: 현재 standalone DB 를 자동 백업 후 reset.
  Future<void> _confirmStandaloneToServer() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Client 모드로 전환'),
        content: const Text(
          '현재 Standalone DB 를 자동으로 백업한 후 Client 모드로 전환됩니다.\n'
          '백업 위치: Documents/mysafetyreport/\n'
          '(저장할 수 없으면 Download/mysafetyreport/)\n\n'
          '계속하시겠습니까?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('전환'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    String? backupPath;
    try {
      if (Platform.isAndroid) {
        final st = await Permission.storage.status;
        if (!st.isGranted) await Permission.storage.request();
      }
      final dir = _backupDir();
      final fileName =
          'standalone_backup_${DateTime.now().millisecondsSinceEpoch}.db';
      final target = File('${dir.path}/$fileName');
      final srcPath = await LocalDbService.getDbPath();
      if (File(srcPath).existsSync()) {
        // 모드 전환은 사용자가 명시 요청 — 진행 중인 동기화·좌표 변환이 멈출 때까지 기다린 뒤 백업(M-25).
        await LocalDbService.closeDb();
        await LocalDbService.exportBackup(target.path);
        backupPath = target.path;
      }
    } catch (e) {
      // 백업 실패해도 모드 전환 자체는 진행 (사용자가 명시 요청)
      if (mounted) {
        showSrSnack(context, '백업 실패 (모드 전환은 진행): $e', kind: SrSnackKind.error);
      }
    }

    if (!mounted) return;
    await context.read<ReportProvider>().resetConfig();
    if (mounted) {
      if (backupPath != null) {
        showSrSnack(
          context,
          '백업 완료: $backupPath',
          kind: SrSnackKind.success,
          duration: const Duration(seconds: 4),
        );
      }
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// Client → Standalone: 3-way 선택 (서버 DB 변환 / 백업 파일 선택 / 처음부터).
  /// 선택 결과는 [PendingDbImportAction] 으로 직렬화돼 setup_screen 의
  /// standalone 로그인 직후 [PendingDbImportAction.apply] 로 실행된다.
  Future<void> _confirmServerToStandalone() async {
    final p = context.read<ReportProvider>();

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Standalone 모드로 전환'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '기존 데이터를 어떻게 시작할지 선택해주세요.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              _ChoiceTile(
                icon: Icons.cloud_download,
                title: '서버 DB 받아 변환',
                subtitle:
                    '현재 Client 서버에서 DB 를 받아 모바일 형식으로 변환.\n'
                    '서버 데이터를 Standalone 에 그대로 가져옴.',
                onTap: () => Navigator.pop(ctx, 'server'),
              ),
              const SizedBox(height: 8),
              _ChoiceTile(
                icon: Icons.folder_open,
                title: '백업 파일 선택',
                subtitle:
                    '.db 파일을 직접 찾아 선택합니다.\n'
                    '서버 live DB라면 같은 폴더의 -wal/-shm도 함께 반영합니다.',
                onTap: () => Navigator.pop(ctx, 'pick_backup'),
              ),
              const SizedBox(height: 8),
              _ChoiceTile(
                icon: Icons.add_circle_outline,
                title: '처음부터 시작',
                subtitle: '빈 DB 로 시작. 로그인 후 첫 동기화로 안전신문고에서 모두 가져옴.',
                onTap: () => Navigator.pop(ctx, 'fresh'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
        ],
      ),
    );

    if (choice == null || !mounted) return;

    PendingDbImportAction? pendingAction;

    if (choice == 'server') {
      // 서버 DB 다운로드 (지금) → Documents/mysafetyreport 에 저장 → pending action 으로 표기.
      // 다운로드는 모드 reset 전에 (Client 자격증명 살아있을 때) 해야 함.
      try {
        if (Platform.isAndroid) {
          final st = await Permission.storage.status;
          if (!st.isGranted) await Permission.storage.request();
        }
      } catch (e) {
        if (mounted) {
          showSrSnack(context, '서버 DB 다운로드 실패: $e', kind: SrSnackKind.error);
        }
        return;
      }
      // 화면이 닫혔으면 다운로드·모드 전환을 시작하지 않는다.
      if (!mounted) return;
      // 진행 다이얼로그(받은 크기·취소). 뒤로가기도 취소로 처리하고(SQ-B06),
      // 닫을 때는 이 route 만 닫는다 — Navigator.of(context).pop() 은 그 사이 맨 위가 바뀌면 설정 화면을 닫는다.
      final cancel = DownloadCancel();
      final progress = ValueNotifier<(int, int?)>((0, null));
      // showDialog 와 같은 설정(루트 navigator·테마 캡처·배경색)으로 route 를 직접 만들어 그 route 만 닫을 수 있게 한다.
      final dialogNavigator = Navigator.of(context, rootNavigator: true);
      final dialogRoute = DialogRoute<void>(
        context: context,
        themes: InheritedTheme.capture(
          from: context,
          to: dialogNavigator.context,
        ),
        barrierColor:
            DialogTheme.of(context).barrierColor ??
            Theme.of(context).dialogTheme.barrierColor ??
            Colors.black54,
        barrierDismissible: false,
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
        builder: (ctx) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) cancel.cancel();
          },
          child: AlertDialog(
            content: ValueListenableBuilder<(int, int?)>(
              valueListenable: progress,
              builder: (_, v, _) => DbDownloadProgressView(
                title: '서버 DB 다운로드 중',
                received: v.$1,
                total: v.$2,
              ),
            ),
            actions: [
              TextButton(onPressed: cancel.cancel, child: const Text('취소')),
            ],
          ),
        ),
      );
      unawaited(dialogNavigator.push(dialogRoute));
      void closeDialog() {
        if (!dialogRoute.isActive) return;
        final navigator = dialogRoute.navigator;
        if (navigator == null) return;
        if (dialogRoute.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(dialogRoute);
        }
      }

      try {
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        final dir = _backupDir();
        final fileName =
            'server_db_${DateTime.now().millisecondsSinceEpoch}.db';
        final target = File('${dir.path}/$fileName');
        await api.downloadDbToFile(
          target.path,
          cancel: cancel,
          onProgress: (received, total) => progress.value = (received, total),
        );
        pendingAction = ConvertServerDbAction(target.path);
      } on DownloadCancelled {
        if (mounted) {
          showSrSnack(context, '서버 DB 다운로드를 취소했습니다. 모드는 바꾸지 않았습니다.');
        }
        return;
      } catch (e) {
        if (mounted) {
          showSrSnack(context, '서버 DB 다운로드 실패: $e', kind: SrSnackKind.error);
        }
        return;
      } finally {
        closeDialog();
        progress.dispose();
      }
    } else if (choice == 'pick_backup') {
      try {
        final result = await FilePicker.pickFiles(
          type: FileType.any,
          allowMultiple: true,
        );
        if (result == null) return;
        final selectedPath = await _stagePickedDbFiles(result);
        if (selectedPath == null || selectedPath.isEmpty) return;
        pendingAction = DetectAndApplyDbFileAction(selectedPath);
      } catch (e) {
        if (mounted) {
          showSrSnack(context, '백업 파일 선택 실패: $e', kind: SrSnackKind.error);
        }
        return;
      }
    }
    // 'fresh' 는 pendingAction = null

    // 대기 작업 저장과 모드 초기화는 함께 하거나 둘 다 하지 않는다(SQ-B06). 다운로드·파일 선택 중 화면이
    // 사라졌으면 여기서 멈춘다 — 대기 작업만 남으면 나중에 엉뚱한 Standalone 로그인에서 적용된다.
    // 받은 파일은 지우지 않는다(사용자 자료).
    if (!mounted) return;
    await PendingDbImportAction.save(pendingAction);
    await p.resetConfig();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  String get _modeLabel {
    final provider = context.read<ReportProvider>();
    if (provider.appMode != AppMode.standalone) return 'Client';
    return provider.isStandaloneDemo ? 'Standalone (데모)' : 'Standalone';
  }

  String get _osLabel => Platform.isAndroid
      ? 'Android ${Platform.operatingSystemVersion}'
      : Platform.operatingSystem;

  /// 도움·문의 카드 링크(버그 제보·기능 요청·사용 가이드). 양쪽 모드 공통.
  Future<void> _openSupportLink(Uri url) async {
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSrSnack(context, '브라우저를 열 수 없습니다.', kind: SrSnackKind.error);
    }
  }

  Future<void> _openOfficialSource() async {
    final url = Uri.parse(_officialSafetyReportUrl);
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSrSnack(context, '브라우저를 열 수 없습니다.', kind: SrSnackKind.error);
    }
  }

  String _themeModeDescription(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.system:
        return '기기의 라이트/다크 설정을 따라갑니다.';
      case AppThemeMode.light:
        return '항상 밝은 테마로 표시합니다.';
      case AppThemeMode.dark:
        return '야간 환경에서 읽기 쉬운 다크 테마를 사용합니다.';
    }
  }

  /// 기준색을 카드 표면 위 AA 글자색으로.
  Color _fg(BuildContext context, Color base) {
    final theme = Theme.of(context);
    return StatusTone.of(
      base,
      brightness: theme.brightness,
      surface: theme.colorScheme.surface,
    ).foreground;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final provider = context.watch<ReportProvider>();
    final isStandalone = provider.appMode == AppMode.standalone;
    final mutedColor = cs.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('앱 설정')),
      // 마지막 항목이 3버튼 내비·가로 컷아웃 아래로 들어가지 않게(SQ-U26).
      body: SingleChildScrollView(
        padding: srPagePadding(context, const EdgeInsets.all(20)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 순서(SQ-U17): 연결·계정(맨 위 도움·문의 포함) → 데이터 관리 → 표시 → 목록·통계 기준 → 권한 → 정보(앱 정보·홈페이지).
            const _SettingsSectionHeader(
              key: ValueKey('settings-section-connection'),
              title: '연결·계정',
            ),
            // ── 연결 방식 카드 ─────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    Icon(
                      isStandalone
                          ? Icons.phone_android_rounded
                          : Icons.dns_rounded,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                isStandalone ? '직접 연결 (스탠드어론)' : 'Client 모드',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              ModeBadge(
                                mode: provider.appMode,
                                isDemo: provider.isStandaloneDemo,
                              ),
                            ],
                          ),
                          Text(
                            isStandalone
                                ? provider.standaloneUsername
                                : provider.baseUrl.isEmpty
                                ? '미설정'
                                : provider.baseUrl,
                            style: TextStyle(fontSize: 12, color: mutedColor),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _confirmModeReset,
                      child: const Text('변경'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // ── 도움·문의 카드 ─────────────────────────────
            // 버그 제보 위치를 사용자가 자주 찾지 못해(2026-09-24 제보) 설정 맨 위(연결 방식 카드 바로 아래)에 둔다.
            // 버그 제보는 이 카드 한 곳에만 있다(SQ-U17: 앱 정보 카드의 중복 버튼 제거).
            _SupportCard(
              onBugReport: () => _openSupportLink(
                SupportLinks.bugReport(
                  appVersion: _appVersion,
                  modeLabel: _modeLabel,
                  osLabel: _osLabel,
                ),
              ),
              onFeatureRequest: () => _openSupportLink(
                SupportLinks.featureRequest(
                  appVersion: _appVersion,
                  modeLabel: _modeLabel,
                  osLabel: _osLabel,
                ),
              ),
              onGuide: () =>
                  _openSupportLink(Uri.parse(SupportLinks.userGuide)),
              onRateApp: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await ReviewPromptService.openStoreListing();
                } catch (_) {
                  showSrSnackOn(
                    messenger,
                    'Play 스토어를 열 수 없습니다.',
                    kind: SrSnackKind.error,
                  );
                }
              },
            ),
            // ── 스탠드어론: 계정 카드 ──────────────────────
            if (isStandalone) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.account_circle_outlined,
                            color: cs.primary,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '안전신문고 계정',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: cs.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _InfoRow(
                        label: '아이디',
                        value: provider.standaloneUsername,
                      ),
                      _InfoRow(
                        label: '휴대폰번호',
                        value: provider.standalonePhoneNumber.isEmpty
                            ? '미설정'
                            : provider.standalonePhoneNumber,
                      ),
                      if (!provider.isStandaloneDemo) ...[
                        const SizedBox(height: 6),
                        const AuthStatusLine(),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('재로그인 / 휴대폰번호 갱신'),
                          onPressed: _showReloginDialog,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 합성 자료만 쓰는 Demo 에는 커뮤니티 계정 연결이 필요 없다.
              if (!provider.isStandaloneDemo) ...[
                const SizedBox(height: 16),
                // 게이트·계정 클라이언트를 넘겨야 공유 동의(상태·철회)·업로드 연결 전환 섹션이 보인다.
                Builder(
                  builder: (context) {
                    CommunityGate? gate;
                    try {
                      gate = Provider.of<CommunityGate>(context, listen: false);
                    } catch (_) {}
                    return CommunityAccountCard(
                      gate: gate,
                      accountClient: gate?.accountClient,
                    );
                  },
                ),
              ],
            ],
            // ── 서버 모드 전용 섹션 시작 ──────────────────────
            if (!isStandalone) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_outlined, color: cs.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _serverVersionLoading
                            ? Text(
                                '서버 버전 확인 중...',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: mutedColor,
                                ),
                              )
                            : _serverVersion == null
                            ? Text(
                                '서버 버전 정보 없음',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: mutedColor,
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '서버 v$_serverVersion',
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (_serverVersionStatus != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        _serverVersionStatus == 'up_to_date'
                                            ? '최신 버전입니다'
                                            : _serverVersionStatus == 'outdated'
                                            ? '업데이트 가능: v$_serverVersionLatest'
                                            : '업데이트 확인 불가',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color:
                                              _serverVersionStatus ==
                                                  'up_to_date'
                                              ? _fg(context, serverAcceptColor)
                                              : _serverVersionStatus ==
                                                    'outdated'
                                              ? _fg(
                                                  context,
                                                  serverPartialAcceptColor,
                                                )
                                              : mutedColor,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      if (_serverVersionLoading)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          visualDensity: VisualDensity.compact,
                          onPressed: _loadServerVersion,
                          tooltip: '새로고침',
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // ── 서버 연결 카드 ─────────────────────────────
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.dns_rounded, color: cs.primary),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '서버 연결',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: cs.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Cloudflare Tunnel 또는 서버 주소를 입력하세요.',
                        style: TextStyle(color: mutedColor, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _urlController,
                        decoration: InputDecoration(
                          labelText: '서버 URL',
                          hintText: 'https://example.com',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.link),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: '서버 URL 지우기',
                            onPressed: () => _urlController.clear(),
                          ),
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _apiController,
                        decoration: InputDecoration(
                          labelText: 'API Key',
                          hintText: 'sk-...',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.vpn_key),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  _obscureKey
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  size: 20,
                                ),
                                tooltip: _obscureKey
                                    ? 'API 키 보기'
                                    : 'API 키 숨기기',
                                onPressed: () =>
                                    setState(() => _obscureKey = !_obscureKey),
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 18),
                                tooltip: '복사',
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(text: _apiController.text),
                                  );
                                  showSrSnack(context, 'API 키가 복사되었습니다.');
                                },
                              ),
                            ],
                          ),
                        ),
                        obscureText: _obscureKey,
                        autocorrect: false,
                      ),
                      const SizedBox(height: 16),
                      // 연결 테스트 결과
                      if (_testResult != null) _buildTestResult(_testResult!),
                      if (_testResult != null) const SizedBox(height: 12),
                      // 버튼 행
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: _testing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.wifi_find, size: 18),
                              label: Text(_testing ? '테스트 중...' : '연결 테스트'),
                              onPressed: _testing || _saving
                                  ? null
                                  : _testConnection,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              icon: const Icon(Icons.save, size: 18),
                              label: const Text('저장'),
                              onPressed: _testing || _saving ? null : _save,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── 서버의 커뮤니티 계정(서버가 세션 주인, 폰은 토큰을 받지 않음) ──
              if (provider.communityAccountSupported) ...[
                CommunityServerAccountCard(
                  baseUrl: provider.baseUrl,
                  apiKey: provider.apiKey,
                ),
                // 이 앱과 서버의 카카오 계정이 다르면 알린다(동의·공유는 계정마다 따로).
                Builder(
                  builder: (context) {
                    CommunityGate? gate;
                    try {
                      gate = Provider.of<CommunityGate>(context, listen: false);
                    } catch (_) {}
                    if (gate == null) return const SizedBox.shrink();
                    return ClientAccountMismatchNotice(
                      gate: gate,
                      baseUrl: provider.baseUrl,
                      apiKey: provider.apiKey,
                    );
                  },
                ),
              ],
            ], // if (!isStandalone) 서버 연결
            if (!isStandalone) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.wifi_tethering,
                            color: _wsRunning
                                ? _fg(context, serverAcceptColor)
                                : mutedColor,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '백그라운드 서버 연결',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: cs.primary,
                              ),
                            ),
                          ),
                          StatusBadge(
                            label: _wsRunning ? '● 실행 중' : '○ 중지됨',
                            color: _wsRunning
                                ? serverAcceptColor
                                : serverRejectColor,
                            fontSize: 12,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '앱 종료 후에도 크롤링 시작·완료 이벤트를 실시간으로 알림으로 받습니다.\n상단 상태바에 지속 알림이 표시됩니다.',
                        style: TextStyle(
                          color: mutedColor,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: _wsToggling
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : OutlinedButton.icon(
                                icon: Icon(
                                  _wsRunning
                                      ? Icons.stop_circle_outlined
                                      : Icons.play_circle_outline,
                                  size: 18,
                                ),
                                label: Text(_wsRunning ? '서비스 중지' : '서비스 시작'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _fg(
                                    context,
                                    _wsRunning
                                        ? serverRejectColor
                                        : serverAcceptColor,
                                  ),
                                  side: BorderSide(
                                    color: _fg(
                                      context,
                                      _wsRunning
                                          ? serverRejectColor
                                          : serverAcceptColor,
                                    ),
                                  ),
                                ),
                                onPressed: _toggleWsService,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ], // if (!isStandalone) WS service
            const SizedBox(height: 24),
            const _SettingsSectionHeader(
              key: ValueKey('settings-section-data'),
              title: '데이터 관리',
            ),
            // ── 데이터베이스 관리 ──────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.storage, color: cs.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '데이터 관리',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // D-06: 하단 '파일' 탭이 이곳으로 이동했다(기능·화면은 그대로).
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text(
                          provider.appMode == AppMode.standalone
                              ? '파일 관리 (내보낸 파일 · Excel)'
                              : '파일 관리 (서버 파일)',
                        ),
                        onPressed: () => AppRoutes.openFiles(context),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '현재 기기(또는 서버)의 데이터를 파일로 백업합니다.\n${DbExportLocation.backupLocationHint}',
                      style: TextStyle(
                        fontSize: 12,
                        color: mutedColor,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: _isBackingUpDb && _dbDownloadCancel != null
                          ? ValueListenableBuilder<(int, int?)>(
                              valueListenable: _dbDownloadProgress,
                              builder: (_, v, _) => Row(
                                children: [
                                  Expanded(
                                    child: DbDownloadProgressView(
                                      title: '서버 DB 받는 중',
                                      received: v.$1,
                                      total: v.$2,
                                    ),
                                  ),
                                  TextButton(
                                    key: const Key('dbBackupCancel'),
                                    onPressed: _dbDownloadCancel?.cancel,
                                    child: const Text('취소'),
                                  ),
                                ],
                              ),
                            )
                          : _isBackingUpDb
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : OutlinedButton.icon(
                              icon: const Icon(Icons.download, size: 18),
                              label: const Text('DB 백업 (다운로드)'),
                              onPressed: _backupDb,
                            ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: _isRestoringDb
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : OutlinedButton.icon(
                              icon: const Icon(Icons.upload, size: 18),
                              label: const Text('DB 복원 (업로드)'),
                              onPressed: _restoreDb,
                            ),
                    ),
                    if (context.watch<ReportProvider>().appMode ==
                            AppMode.standalone &&
                        _previousImportBackup != null &&
                        !_isRestoringDb) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          icon: const Icon(Icons.history, size: 18),
                          label: const Text('직전 DB 로 되돌리기'),
                          onPressed: _revertToPreviousDb,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (!isStandalone) ...[
              const SizedBox(height: 16),
              // ── 크롤링 자동 저장 카드 ──────────────────────
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.save_outlined, color: cs.primary),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '크롤링 자동 저장',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: cs.primary,
                              ),
                            ),
                          ),
                          if (_filterLoading) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '크롤링 완료 후 자동으로 내보내기를 실행합니다.',
                        style: TextStyle(color: mutedColor, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '엑셀 자동 저장',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          '크롤링 완료 후 서버에 Excel 파일을 자동 생성합니다.',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _autoExportExcel,
                        onChanged: _filterLoading
                            ? null
                            : (v) {
                                setState(() => _autoExportExcel = v);
                                _toggleFilter('auto_export_excel', v);
                              },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '구글 스프레드시트 자동 업로드',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: const Text(
                          '크롤링 완료 후 구글 시트에 자동 업로드합니다.',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _autoExportSheet,
                        onChanged: _filterLoading
                            ? null
                            : (v) {
                                setState(() => _autoExportSheet = v);
                                _toggleFilter('auto_export_sheet', v);
                              },
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            const _SettingsSectionHeader(
              key: ValueKey('settings-section-display'),
              title: '표시',
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.dark_mode_outlined, color: cs.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '화면 테마',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 라디오 3줄 + 설명 상자 대신 3칸 세그먼트 한 줄(SQ-U17).
                    SegmentedButton<AppThemeMode>(
                      key: const ValueKey('settings-theme-mode'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: AppThemeMode.system,
                          label: Text('시스템'),
                          tooltip: '시스템 설정 사용',
                        ),
                        ButtonSegment(
                          value: AppThemeMode.light,
                          label: Text('라이트'),
                          tooltip: '라이트 모드',
                        ),
                        ButtonSegment(
                          value: AppThemeMode.dark,
                          label: Text('다크'),
                          tooltip: '다크 모드',
                        ),
                      ],
                      selected: {provider.themeMode},
                      onSelectionChanged: (value) => context
                          .read<ReportProvider>()
                          .setThemeMode(value.first),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _themeModeDescription(provider.themeMode),
                      style: TextStyle(color: mutedColor, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _SettingsSectionHeader(
              key: ValueKey('settings-section-list-basis'),
              title: '목록·통계 기준',
            ),
            // ── 목록·통계 기준 카드 (양쪽 모드 공통, 옛 이름 "기타 데이터 필터 세팅") ──────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.filter_list, color: cs.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '목록·통계 기준',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                          ),
                        ),
                        if (_filterLoading) ...[
                          const SizedBox(width: 8),
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isStandalone
                          ? '신고 목록·대시보드·통계에 함께 적용됩니다. 변경 시 데이터가 즉시 갱신됩니다.'
                          : '신고 목록·대시보드·통계에 함께 적용되며 웹앱 설정과 동기화됩니다. 변경 시 데이터가 즉시 갱신됩니다.',
                      style: TextStyle(color: mutedColor, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '취하 데이터 숨기기',
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: const Text(
                        '처리상태가 취하인 신고를 목록에서 제외합니다.',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: _excludeWithdraw,
                      onChanged: _filterLoading
                          ? null
                          : (v) {
                              setState(() => _excludeWithdraw = v);
                              _toggleFilter('exclude_withdraw', v);
                            },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '중복 신고 대표건만 반영',
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: const Text(
                        '전체 신고 조회, 차량/주소 검색, 대시보드, 통계 등의 기본 집계 기준을 대표건 1건으로 맞춥니다.\n비활성화할 경우 원본 신고 row를 모두 반영합니다. 검토 필요 그룹은 항상 child 전체를 보여줍니다.',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: _useRepresentativeRecords,
                      onChanged: _filterLoading
                          ? null
                          : (v) {
                              setState(() => _useRepresentativeRecords = v);
                              _toggleFilter('use_representative_records', v);
                            },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _SettingsSectionHeader(
              key: ValueKey('settings-section-permissions'),
              title: '권한',
            ),
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(SrRadius.lg),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PermissionScreen()),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(Icons.security, color: cs.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '권한 설정',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: cs.primary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '알림 접근, 배터리 최적화 제외, 백그라운드 서비스 등 권한을 관리합니다.',
                              style: TextStyle(color: mutedColor, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: mutedColor),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _SettingsSectionHeader(
              key: ValueKey('settings-section-about'),
              title: '정보',
            ),
            // ── 앱 정보 카드 ──────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: cs.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '앱 정보',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _InfoRow(
                      label: '앱 버전',
                      value: _appVersion.isEmpty ? '...' : 'v$_appVersion',
                    ),
                    const _InfoRow(label: '플랫폼', value: 'Android / iOS'),
                    const _InfoRow(label: '공식 출처', value: '안전신문고'),
                    const SizedBox(height: 6),
                    SelectableText(
                      _officialSafetyReportUrl,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_browser, size: 18),
                        label: const Text('안전신문고 공식 사이트 열기'),
                        onPressed: _openOfficialSource,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.secondaryContainer.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(SrRadius.lg),
                        border: Border.all(
                          color: cs.secondary.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '이 앱은 안전신문고의 공식 앱이 아니며 행정안전부 또는 정부기관을 대표하지 않습니다.',
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.45,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '안전신문고 데이터를 사용자의 편의를 위해 조회·정리해 보여주는 비공식 도구입니다.',
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.45,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '원문 확인과 실제 민원 처리는 안전신문고 공식 서비스에서 진행해 주세요.',
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.45,
                              color: cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '※ 인터넷 권한(INTERNET)은 Android 일반 권한으로 설치 시 별도 요청 없이 자동 부여됩니다.',
                      style: TextStyle(
                        fontSize: SrFontSize.caption,
                        color: mutedColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.language, size: 18),
                label: const Text('홈페이지 바로가기'),
                onPressed: () async {
                  final url = Uri.parse(SupportLinks.userGuide);
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildTestResult(_TestResult result) {
    final (tone, icon) = switch (result.type) {
      _ResultType.success => (context.tone(SrTone.success), Icons.check_circle),
      _ResultType.warn => (context.tone(SrTone.warning), Icons.warning),
      _ResultType.error => (context.tone(SrTone.danger), Icons.error),
    };
    final fg = tone.foreground;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(SrRadius.md),
        border: Border.all(color: tone.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              result.message,
              style: TextStyle(color: fg, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _TestResult {
  final _ResultType type;
  final String message;
  const _TestResult.success(this.message) : type = _ResultType.success;
  const _TestResult.warn(this.message) : type = _ResultType.warn;
  const _TestResult.error(this.message) : type = _ResultType.error;
}

enum _ResultType { success, warn, error }

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// 설정 묶음 머리(SQ-U17). 모든 묶음이 같은 모양·색을 쓴다.
class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Semantics(
      header: true,
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: context.sr.textSecondary,
        ),
      ),
    ),
  );
}

/// Server → Standalone 전환 시 3-way 선택 다이얼로그용 타일.
class _ChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(SrRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(SrRadius.lg),
          color: cs.primary.withValues(alpha: 0.04),
        ),
        child: Row(
          children: [
            Icon(icon, color: cs.primary, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: SrFontSize.caption,
                      color: cs.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 설정 맨 위 도움·문의 카드. 버그 제보는 설정에서 이 카드 한 곳에만 있다(2026-09-24 결정, SQ-U17).
class _SupportCard extends StatelessWidget {
  final VoidCallback onBugReport;
  final VoidCallback onFeatureRequest;
  final VoidCallback onGuide;
  final VoidCallback onRateApp;

  const _SupportCard({
    required this.onBugReport,
    required this.onFeatureRequest,
    required this.onGuide,
    required this.onRateApp,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.support_agent, color: cs.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '도움·문의',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: cs.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '앱이 이상하게 동작하면 알려 주세요. 앱 버전·모드가 미리 채워진 제보 양식이 열립니다.',
              style: TextStyle(fontSize: 13, height: 1.45, color: cs.onSurface),
            ),
            const SizedBox(height: 4),
            Text(
              'GitHub 계정이 필요하고, 제보는 공개됩니다. 아이디·API 키·차량번호 같은 개인정보는 적지 마세요.',
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('버그 제보하기'),
              onPressed: onBugReport,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.lightbulb_outline, size: 18),
                    label: const Text('기능 요청'),
                    onPressed: onFeatureRequest,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('사용 가이드'),
                    onPressed: onGuide,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.star_outline, size: 18),
              label: const Text('Play 스토어에서 평가하기'),
              onPressed: onRateApp,
            ),
          ],
        ),
      ),
    );
  }
}

/// DB 다운로드 진행 표시: 제목, 받은 크기 / 전체 크기, 진행 막대(전체를 모르면 흐르는 막대).
class DbDownloadProgressView extends StatelessWidget {
  const DbDownloadProgressView({
    super.key,
    required this.title,
    required this.received,
    required this.total,
  });

  final String title;
  final int received;
  final int? total;

  static String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final t = total;
    final known = t != null && t > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          known
              ? '$title ${_mb(received)} / ${_mb(t)}MB'
              : '$title ${_mb(received)}MB',
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: known ? (received / t).clamp(0.0, 1.0) : null,
        ),
      ],
    );
  }
}
