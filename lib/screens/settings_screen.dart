import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/permission_service.dart';
import '../services/standalone_auth_service.dart';
import 'permission_screen.dart';
import 'setup_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';

const _officialSafetyReportUrl = 'https://www.safetyreport.go.kr/';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlController = TextEditingController();
  final _apiController = TextEditingController();
  bool _obscureKey = true;
  bool _testing = false;
  _TestResult? _testResult;
  bool _wsRunning = false;
  bool _wsToggling = false;
  bool _isBackingUpDb = false;
  bool _isRestoringDb = false;

  // 기타 데이터 필터 세팅
  bool _excludeWithdraw = true;
  bool _normalizePolice = true;
  bool _autoExportExcel = true;
  bool _autoExportSheet = true;
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
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = info.version);
    });
  }

  Future<void> _loadServerVersion() async {
    final api = _buildApi();
    if (api == null) return;
    setState(() => _serverVersionLoading = true);
    try {
      final p = context.read<ReportProvider>();
      final baseUrl = p.baseUrl.trimRight().replaceAll(RegExp(r'/$'), '');
      final headers = {'X-API-Key': p.apiKey};
      final res = await http
          .get(Uri.parse('$baseUrl/api/v1/server/version'), headers: headers)
          .timeout(const Duration(seconds: 5));
      if (mounted) {
        if (res.statusCode == 200) {
          final j = jsonDecode(res.body);
          final ver = j['version'] as String?;
          final latest = j['latest_version'] as String?;
          final upToDate = j['up_to_date'] as bool?;
          final status = upToDate == null
              ? null
              : upToDate
              ? 'up_to_date'
              : 'outdated';
          setState(() {
            _serverVersion = ver;
            _serverVersionStatus = status;
            _serverVersionLatest = latest;
          });
        } else {
          setState(() => _serverVersion = null);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _serverVersion = null);
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
          _normalizePolice = p.normalizePolice;
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
          _normalizePolice = cfg['normalize_police'] as bool? ?? true;
          _autoExportExcel = cfg['auto_export_excel'] as bool? ?? true;
          _autoExportSheet = cfg['auto_export_sheet'] as bool? ?? true;
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
      } else if (key == 'normalize_police') {
        await p.setStandaloneFilter(normalizePolice: value);
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
    await _checkWsStatus();
    setState(() => _wsToggling = false);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
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

    final cleanUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;

    try {
      final response = await http
          .get(
            Uri.parse('$cleanUrl/api/v1/summary'),
            headers: {'X-API-Key': key, 'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));

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
      setState(() {
        _testResult = _TestResult.error('연결 실패: $e');
      });
    } finally {
      setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    final key = _apiController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('모든 필드를 입력해주세요.')));
      return;
    }
    final provider = context.read<ReportProvider>();
    await provider.setConfig(url, key);
    // 설정 변경 후 모든 데이터 새로고침
    provider.refreshAll();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('설정이 저장되었습니다. 데이터를 불러오는 중...'),
          backgroundColor: Colors.green,
        ),
      );
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
      builder: (ctx) => StatefulBuilder(
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
                  style: const TextStyle(color: Colors.red, fontSize: 13),
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
                            username == LocalDbService.playReviewDemoUsername &&
                            passwordCtrl.text ==
                                LocalDbService.playReviewDemoPassword &&
                            rawPhone == LocalDbService.playReviewDemoPhone;
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
                          await ctx.read<ReportProvider>().setStandaloneConfig(
                            username,
                            phoneNumber: isDemoLogin ? rawPhone : phone,
                            isDemoMode: isDemoLogin,
                          );
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                isDemoLogin ? '데모 모드 전환 완료' : '재로그인 완료',
                              ),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        setDlg(() {
                          err = e.toString().replaceFirst('Exception: ', '');
                          loggingIn = false;
                        });
                      }
                    },
              child: loggingIn
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('로그인'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _backupDb() async {
    if (_isBackingUpDb) return;
    setState(() => _isBackingUpDb = true);

    try {
      if (Platform.isAndroid) {
        final status = await Permission.storage.status;
        if (!status.isGranted) {
          await Permission.storage.request();
        }
      }

      final dir = Directory('/storage/emulated/0/Documents/mysafetyreport');
      if (!dir.existsSync()) {
        try {
          dir.createSync(recursive: true);
        } catch (_) {
          final altDir = Directory(
            '/storage/emulated/0/Download/mysafetyreport',
          );
          if (!altDir.existsSync()) altDir.createSync(recursive: true);
        }
      }

      final p = context.read<ReportProvider>();
      final isStandalone = p.appMode == AppMode.standalone;

      final targetDir = dir.existsSync()
          ? dir
          : Directory('/storage/emulated/0/Download/mysafetyreport');
      final fileName =
          'backup_data_${DateTime.now().millisecondsSinceEpoch}.db';
      final targetFile = File('${targetDir.path}/$fileName');

      if (isStandalone) {
        await LocalDbService.exportBackup(targetFile.path);
      } else {
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        final bytes = await api.downloadDb();
        await targetFile.writeAsBytes(bytes);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('DB 백업 완료: ${targetFile.path}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('DB 백업 실패: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
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
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('복원 시작'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                kind == 'server'
                    ? '서버 DB 변환 복원이 완료되었습니다.'
                    : '모바일 백업 복원이 완료되었습니다.',
              ),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // Client: 서버에 업로드 → 서버가 자동 감지/변환
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        final res = await api.uploadDb(selectedPath);
        if (mounted) {
          final kind = res['kind'] as String? ?? '';
          final imported = res['imported'];
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '서버 DB 복원 완료 (${kind == 'mobile' ? '모바일→서버 변환' : '서버 형식'}, $imported건)',
              ),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
      return; // 아래 standalone 전용 블록 스킵
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('DB 복원 실패: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isRestoringDb = false);
    }
  }

  // ── 모드 변경 ─────────────────────────────────────────────────
  // Standalone → Client: 현재 모바일 DB 자동 백업 후 reset.
  // Client → Standalone: 3-way 선택 (서버 DB 변환 / 백업 파일 선택 / 처음부터).

  /// Documents/mysafetyreport (없으면 Download/mysafetyreport) 디렉토리 보장.
  static Directory _backupDir() {
    final docs = Directory('/storage/emulated/0/Documents/mysafetyreport');
    if (docs.existsSync()) return docs;
    try {
      docs.createSync(recursive: true);
      return docs;
    } catch (_) {
      final dl = Directory('/storage/emulated/0/Download/mysafetyreport');
      if (!dl.existsSync()) dl.createSync(recursive: true);
      return dl;
    }
  }

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
          '백업 위치: Documents/mysafetyreport/\n\n'
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
        await LocalDbService.exportBackup(target.path);
        backupPath = target.path;
      }
    } catch (e) {
      // 백업 실패해도 모드 전환 자체는 진행 (사용자가 명시 요청)
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('백업 실패 (모드 전환은 진행): $e')));
      }
    }

    if (!mounted) return;
    await context.read<ReportProvider>().resetConfig();
    if (mounted) {
      if (backupPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('백업 완료: $backupPath'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SetupScreen()),
        (_) => false,
      );
    }
  }

  /// Client → Standalone: 3-way 선택 (서버 DB 변환 / 백업 파일 선택 / 처음부터).
  /// 선택 결과는 SharedPreferences 의 'pending_db_import' 에 저장 → setup_screen
  /// 의 standalone 로그인 직후 LocalDbService 가 적용.
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

    final prefs = await SharedPreferences.getInstance();
    String? pendingAction;

    if (choice == 'server') {
      // 서버 DB 다운로드 (지금) → Documents/mysafetyreport 에 저장 → pending action 으로 표기.
      // 다운로드는 모드 reset 전에 (Client 자격증명 살아있을 때) 해야 함.
      try {
        if (Platform.isAndroid) {
          final st = await Permission.storage.status;
          if (!st.isGranted) await Permission.storage.request();
        }
        // 진행 다이얼로그
        unawaited(
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Expanded(child: Text('서버 DB 다운로드 중...')),
                ],
              ),
            ),
          ),
        );
        final api = ApiService(baseUrl: p.baseUrl, apiKey: p.apiKey);
        final bytes = await api.downloadDb();
        final dir = _backupDir();
        final fileName =
            'server_db_${DateTime.now().millisecondsSinceEpoch}.db';
        final target = File('${dir.path}/$fileName');
        await target.writeAsBytes(bytes);
        pendingAction = 'convert:${target.path}';
        if (mounted) Navigator.of(context).pop(); // 진행 다이얼로그 닫기
      } catch (e) {
        if (mounted) {
          Navigator.of(context).pop(); // 진행 다이얼로그 닫기 (실패 시)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('서버 DB 다운로드 실패: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
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
        pendingAction = 'file:$selectedPath';
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('백업 파일 선택 실패: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }
    // 'fresh' 는 pendingAction = null

    if (pendingAction != null) {
      await prefs.setString('pending_db_import', pendingAction);
    } else {
      await prefs.remove('pending_db_import');
    }

    if (!mounted) return;
    await context.read<ReportProvider>().resetConfig();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SetupScreen()),
        (_) => false,
      );
    }
  }

  /// GitHub 이슈 트래커로 이동 (양쪽 모드 공통, 버그/기능요청).
  Future<void> _openBugReport() async {
    final url = Uri.parse(
      'https://github.com/Fentanest/safetyreport-mobile/issues',
    );
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('브라우저를 열 수 없습니다.')));
    }
  }

  Future<void> _openOfficialSource() async {
    final url = Uri.parse(_officialSafetyReportUrl);
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('브라우저를 열 수 없습니다.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<ReportProvider>();
    final isStandalone = provider.appMode == AppMode.standalone;

    return Scaffold(
      appBar: AppBar(title: const Text('앱 설정')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                      color: isStandalone
                          ? const Color(0xFF0F9D58)
                          : cs.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isStandalone ? '직접 연결 (스탠드어론)' : 'Client 모드',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            isStandalone
                                ? provider.standaloneUsername
                                : provider.baseUrl.isEmpty
                                ? '미설정'
                                : provider.baseUrl,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
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
                          const Icon(
                            Icons.account_circle_outlined,
                            color: Color(0xFF0F9D58),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '안전신문고 계정',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F9D58),
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
                            ? const Text(
                                '서버 버전 확인 중...',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey,
                                ),
                              )
                            : _serverVersion == null
                            ? const Text(
                                '서버 버전 정보 없음',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey,
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
                                              ? Colors.green
                                              : _serverVersionStatus ==
                                                    'outdated'
                                              ? Colors.orange
                                              : Colors.grey,
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
                          Text(
                            '서버 연결',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Cloudflare Tunnel 또는 서버 주소를 입력하세요.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
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
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('API 키가 복사되었습니다.'),
                                    ),
                                  );
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
                              onPressed: _testing ? null : _testConnection,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              icon: const Icon(Icons.save, size: 18),
                              label: const Text('저장'),
                              onPressed: _save,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
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
                          Text(
                            '크롤링 자동 저장',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
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
                      const Text(
                        '크롤링 완료 후 자동으로 내보내기를 실행합니다.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
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
              const SizedBox(height: 16),
            ], // if (!isStandalone)
            // ── 기타 데이터 필터 세팅 카드 (양쪽 모드 공통) ──────
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
                        Text(
                          '기타 데이터 필터 세팅',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: cs.primary,
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
                          ? '변경 시 데이터가 즉시 갱신됩니다.'
                          : '웹앱 설정과 동기화됩니다. 변경 시 데이터가 즉시 갱신됩니다.',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
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
                        '경찰 기관명 정규화',
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: const Text(
                        '처리기관명을 "XX경찰서" 형태로 통일합니다.',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: _normalizePolice,
                      onChanged: _filterLoading
                          ? null
                          : (v) {
                              setState(() => _normalizePolice = v);
                              _toggleFilter('normalize_police', v);
                            },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── 데이터베이스 관리 ──────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.storage, color: cs.secondary),
                        const SizedBox(width: 8),
                        Text(
                          '데이터베이스 관리',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: cs.secondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '현재 기기(또는 서버)의 데이터를 파일로 백업합니다.\n저장 경로: Documents/mysafetyreport/',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: _isBackingUpDb
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
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── 앱 정보 카드 ──────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: cs.secondary),
                        const SizedBox(width: 8),
                        Text(
                          '앱 정보',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: cs.secondary,
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
                    const SelectableText(
                      _officialSafetyReportUrl,
                      style: TextStyle(fontSize: 12.5, height: 1.4),
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
                        color: Colors.blueGrey.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.blueGrey.shade100),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '이 앱은 안전신문고의 공식 앱이 아니며 행정안전부 또는 정부기관을 대표하지 않습니다.',
                            style: TextStyle(fontSize: 12.5, height: 1.45),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '안전신문고 데이터를 사용자의 편의를 위해 조회·정리해 보여주는 비공식 도구입니다.',
                            style: TextStyle(fontSize: 12.5, height: 1.45),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '원문 확인과 실제 민원 처리는 안전신문고 공식 서비스에서 진행해 주세요.',
                            style: TextStyle(fontSize: 12.5, height: 1.45),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.bug_report_outlined, size: 18),
                        label: const Text('버그 제보 / 기능 요청'),
                        onPressed: _openBugReport,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '※ 인터넷 권한(INTERNET)은 Android 일반 권한으로 설치 시 별도 요청 없이 자동 부여됩니다.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
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
                            color: _wsRunning ? Colors.green : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '백그라운드 서버 연결',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _wsRunning
                                  ? Colors.green.shade50
                                  : Colors.red.shade50,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _wsRunning
                                    ? Colors.green.shade300
                                    : Colors.red.shade200,
                              ),
                            ),
                            child: Text(
                              _wsRunning ? '● 실행 중' : '○ 중지됨',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: _wsRunning
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '앱 종료 후에도 크롤링 시작·완료 이벤트를 실시간으로 알림으로 받습니다.\n상단 상태바에 지속 알림이 표시됩니다.',
                        style: TextStyle(
                          color: Colors.grey,
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
                                  foregroundColor: _wsRunning
                                      ? Colors.red
                                      : Colors.green,
                                  side: BorderSide(
                                    color: _wsRunning
                                        ? Colors.red
                                        : Colors.green,
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
            const SizedBox(height: 16),

            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PermissionScreen()),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(Icons.security, color: cs.tertiary ?? cs.primary),
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
                                color: cs.tertiary ?? cs.primary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              '알림 접근, 배터리 최적화 제외, 백그라운드 서비스 등 권한을 관리합니다.',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Colors.grey),
                    ],
                  ),
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
                  final url = Uri.parse(
                    'https://hb.worklazy.net/mysafetyreport/',
                  );
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
    Color bg, fg;
    IconData icon;
    switch (result.type) {
      case _ResultType.success:
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        icon = Icons.check_circle;
        break;
      case _ResultType.warn:
        bg = Colors.orange.shade50;
        fg = Colors.orange.shade800;
        icon = Icons.warning;
        break;
      case _ResultType.error:
        bg = Colors.red.shade50;
        fg = Colors.red.shade800;
        icon = Icons.error;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: fg.withOpacity(0.3)),
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
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
  }
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
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: cs.primary.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(10),
          color: cs.primary.withOpacity(0.04),
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
                      fontSize: 11,
                      color: Colors.grey.shade700,
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
