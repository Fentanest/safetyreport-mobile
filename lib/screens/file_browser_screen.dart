import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/app_mode.dart';
import '../models/file_item.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/app_storage_paths.dart';
import '../services/excel_export_service.dart';
import '../theme/sr_colors.dart';
import '../server_palette.dart';

/// 확장자 → MIME type 매핑 (top-level — 모든 State 에서 공유).
/// open_filex 가 자동 추론에 실패하는 경우(특히 Android에서 xlsx)가 있어 명시적으로 전달.
String? mimeForPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  const map = {
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'xls': 'application/vnd.ms-excel',
    'csv': 'text/csv',
    'pdf': 'application/pdf',
    'docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'doc': 'application/msword',
    'pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'ppt': 'application/vnd.ms-powerpoint',
    'txt': 'text/plain',
    'json': 'application/json',
    'log': 'text/plain',
    'db': 'application/octet-stream',
  };
  return map[ext];
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

IconData fileIconForName(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  switch (ext) {
    case 'db':
      return Icons.storage;
    case 'log':
      return Icons.article;
    case 'csv':
      return Icons.table_chart;
    case 'xlsx':
    case 'xls':
      return Icons.table_chart;
    case 'json':
      return Icons.data_object;
    case 'txt':
      return Icons.text_snippet;
    case 'ini':
      return Icons.settings;
    case 'png':
    case 'jpg':
    case 'jpeg':
      return Icons.image;
    default:
      return Icons.insert_drive_file;
  }
}

/// Standalone 파일 목록의 항목 1개. 목록을 읽을 때 한 번만 stat 한다(SQ-P11).
@immutable
class LocalFileEntry {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  const LocalFileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });
}

/// 파일 화면이 쓰는 로컬 파일 시스템 접근. 화면 build 는 이것을 부르지 않는다(목록을 읽을 때만 비동기로 쓴다).
class LocalFileSource {
  const LocalFileSource();

  /// 내보내기 루트(mysafetyreport).
  Future<Directory> root() async => AppStoragePaths.exportsRoot();

  Future<bool> exists(Directory dir) => dir.exists();

  /// [dir] 의 바로 아래 항목을 비동기로 나열하고 각 항목을 한 번씩 stat 한다(정렬 전).
  Future<List<LocalFileEntry>> list(Directory dir) async {
    final entries = <LocalFileEntry>[];
    await for (final entity in dir.list()) {
      final stat = await entity.stat();
      entries.add(
        LocalFileEntry(
          path: entity.path,
          name: entity.path.split('/').last,
          // 예전: entity is Directory || FileSystemEntity.isDirectorySync(path) — stat 도 링크를 따라간다.
          isDirectory:
              entity is Directory ||
              stat.type == FileSystemEntityType.directory,
          size: stat.size,
          modified: stat.modified,
        ),
      );
    }
    return entries;
  }
}

int _compareNamesDescending(String a, String b) =>
    b.toLowerCase().compareTo(a.toLowerCase());

/// 폴더 먼저, 그 안에서는 이름(대소문자 무시) 내림차순 — 예전 정렬과 같다.
@visibleForTesting
int compareLocalFileEntries(LocalFileEntry a, LocalFileEntry b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return _compareNamesDescending(a.name, b.name);
}

class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({
    super.key,
    this.localFiles = const LocalFileSource(),
  });

  /// Standalone 로컬 파일 접근. 테스트는 가짜 나열기를 넣는다.
  final LocalFileSource localFiles;

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  // server mode state
  List<FileItem>? _rootItems;
  String? _error;
  late ApiService _api;
  String _baseUrl = '';
  String _apiKey = '';
  String _currentPath = '';

  // standalone mode state
  List<LocalFileEntry> _localFiles = const [];
  String _localRootPath = '';
  String _currentLocalPath = '';
  ExcelExportCancelToken? _exportCancel;
  ExcelExportProgress? _exportProgress;
  bool get _exporting => _exportCancel != null;
  final Map<String, LocalFileEntry> _selectedLocalFiles = {};
  final Map<String, FileItem> _selectedServerFiles = {};

  bool _loading = true;
  late final bool _isStandalone;

  int _lastRefreshNonce = 0;

  static final _modifiedFormat = DateFormat('yy/MM/dd HH:mm');

  int _compareNamesDesc(String a, String b) => _compareNamesDescending(a, b);

  bool get _isLocalRoot =>
      _localRootPath.isEmpty || _currentLocalPath == _localRootPath;

  String _localDisplayPath(String path) {
    if (_localRootPath.isEmpty || path.isEmpty || path == _localRootPath) {
      return 'mysafetyreport';
    }
    if (path.startsWith('$_localRootPath/')) {
      return 'mysafetyreport/${path.substring(_localRootPath.length + 1)}';
    }
    return path;
  }

  String? get _parentLocalPath {
    if (_isLocalRoot || _currentLocalPath.isEmpty) return null;
    final parent = Directory(_currentLocalPath).parent.path;
    if (!parent.startsWith(_localRootPath)) return _localRootPath;
    return parent;
  }

  bool get _selectionMode => _isStandalone
      ? _selectedLocalFiles.isNotEmpty
      : _selectedServerFiles.isNotEmpty;

  int get _selectedCount =>
      _isStandalone ? _selectedLocalFiles.length : _selectedServerFiles.length;

  Future<void> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.storage.status;
    if (!status.isGranted) {
      await Permission.storage.request();
    }
  }

  void _clearSelection() {
    if (!_selectionMode) return;
    setState(() {
      _selectedLocalFiles.clear();
      _selectedServerFiles.clear();
    });
  }

  void _toggleLocalSelection(LocalFileEntry entity) {
    if (entity.isDirectory) return;
    final path = entity.path;
    setState(() {
      if (_selectedLocalFiles.containsKey(path)) {
        _selectedLocalFiles.remove(path);
      } else {
        _selectedLocalFiles[path] = entity;
      }
    });
  }

  void _toggleServerSelection(FileItem item) {
    if (item.isDir) return;
    setState(() {
      if (_selectedServerFiles.containsKey(item.path)) {
        _selectedServerFiles.remove(item.path);
      } else {
        _selectedServerFiles[item.path] = item;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _isStandalone =
        Provider.of<ReportProvider>(context, listen: false).appMode ==
        AppMode.standalone;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isStandalone) {
        _loadLocalFiles();
      } else {
        final p = context.read<ReportProvider>();
        _baseUrl = p.baseUrl;
        _apiKey = p.apiKey;
        _api = ApiService(baseUrl: _baseUrl, apiKey: _apiKey);
        _loadServer('');
      }
    });
  }

  /// 탭 전환 시 ReportProvider.bumpFilesRefresh() 로 nonce 변경되면 재로드.
  /// Provider 의 다른 알림으로는 다시 그리지 않도록 이 값만 구독한다(SQ-P11).
  void _watchRefreshNonce(BuildContext context) {
    final nonce = context.select<ReportProvider, int>(
      (p) => p.filesRefreshNonce,
    );
    if (nonce != _lastRefreshNonce) {
      _lastRefreshNonce = nonce;
      if (nonce != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_isStandalone) {
            _loadLocalFiles(_currentLocalPath);
          } else {
            _loadServer(_currentPath);
          }
        });
      }
    }
  }

  // ── 스탠드어론 ─────────────────────────────────────────────────────────────

  Future<Directory> _exportsDir() => widget.localFiles.root();

  Future<void> _loadLocalFiles([String? path]) async {
    setState(() {
      _loading = true;
      _error = null;
      _selectedLocalFiles.clear();
    });
    try {
      final rootDir = await _exportsDir();
      var targetPath = path;
      if (targetPath == null || targetPath.isEmpty) {
        targetPath = _currentLocalPath.isEmpty
            ? rootDir.path
            : _currentLocalPath;
      }
      var dir = Directory(targetPath);
      if (!await widget.localFiles.exists(dir)) {
        dir = rootDir;
      }
      final entries = (await widget.localFiles.list(dir))
        ..sort(compareLocalFileEntries);
      if (mounted) {
        setState(() {
          _localRootPath = rootDir.path;
          _currentLocalPath = dir.path;
          _localFiles = entries;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _exportExcel() async {
    if (_exporting) return;
    final p = context.read<ReportProvider>();
    await _ensureStoragePermission();
    if (!mounted || _exporting) return;

    // 화면을 떠나도 예전처럼 내보내기는 끝까지 진행해 파일을 저장한다(결과 안내만 생략).
    final cancel = ExcelExportCancelToken();
    setState(() {
      _exportCancel = cancel;
      _exportProgress = null;
    });

    try {
      final dir = await _exportsDir();
      final saved = await ExcelExportService.exportToDirectory(
        dir,
        excludeWithdraw: p.excludeWithdraw,
        cancel: cancel,
        onProgress: (progress) {
          if (mounted) setState(() => _exportProgress = progress);
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장됨: ${saved.path.split('/').last}')),
        );
        await _loadLocalFiles(_currentLocalPath);
      }
    } on ExcelExportCancelled {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('내보내기를 취소했습니다.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('내보내기 실패: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      _exportCancel = null;
      _exportProgress = null;
      if (mounted) setState(() {});
    }
  }

  void _cancelExport() {
    final cancel = _exportCancel;
    if (cancel == null || cancel.isCancelled) return;
    setState(cancel.cancel);
  }

  String _exportLabel() {
    final cancel = _exportCancel;
    if (cancel == null) return 'Excel 내보내기';
    if (cancel.isCancelled) return '취소하는 중...';
    final progress = _exportProgress;
    final fraction = progress?.fraction;
    final status = switch (progress?.phase) {
      ExcelExportPhase.building => '엑셀 만드는 중',
      ExcelExportPhase.saving => '저장하는 중',
      _ when fraction != null => '내보내는 중 ${(fraction * 100).floor()}%',
      _ => '내보내는 중...',
    };
    return '$status · 취소';
  }

  Future<File> _stageTempCopy(File source) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final name = source.path.split('/').last;
    final staged = File('${dir.path}/open_${stamp}_$name');
    if (staged.existsSync()) {
      await staged.delete();
    }
    return source.copy(staged.path);
  }

  Future<void> _openSavedFile(File file) async {
    final mime = mimeForPath(file.path);
    final result = await OpenFilex.open(file.path, type: mime);
    if (result.type == ResultType.noAppToOpen && mounted) {
      await Share.shareXFiles([
        XFile(file.path),
      ], subject: file.path.split('/').last);
    } else if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('파일 열기 실패: ${result.message}')));
    }
  }

  void _openLocalFile(LocalFileEntry f) async {
    // 일부 기기에서는 외부 저장소 원본을 바로 열 때 MANAGE_EXTERNAL_STORAGE를 요구하므로
    // 앱 임시 디렉토리로 복사한 뒤 연다.
    try {
      final staged = await _stageTempCopy(File(f.path));
      await _openSavedFile(staged);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('파일 준비 실패: $e')));
    }
  }

  Future<File> _saveDownloadedFile(
    DownloadedFilePayload payload, {
    String subdir = 'downloads',
  }) async {
    await _ensureStoragePermission();
    final dir = AppStoragePaths.subDir(subdir);
    final baseName = payload.filename.trim().isEmpty
        ? 'download_${DateTime.now().millisecondsSinceEpoch}'
        : payload.filename.trim();
    var target = File('${dir.path}/$baseName');
    if (!target.existsSync()) {
      await target.writeAsBytes(payload.bytes);
      return target;
    }

    final dot = baseName.lastIndexOf('.');
    final stem = dot >= 0 ? baseName.substring(0, dot) : baseName;
    final ext = dot >= 0 ? baseName.substring(dot) : '';
    var index = 2;
    while (target.existsSync()) {
      target = File('${dir.path}/${stem}_$index$ext');
      index++;
    }
    await target.writeAsBytes(payload.bytes);
    return target;
  }

  Future<bool> _downloadServerItems(List<FileItem> items) async {
    if (items.isEmpty) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          items.length == 1 ? '다운로드 중...' : '${items.length}개 파일 묶음 다운로드 중...',
        ),
        duration: const Duration(seconds: 30),
      ),
    );

    try {
      final payload = items.length == 1
          ? await _api.downloadFile(items.first.path)
          : await _api.downloadFilesArchive(
              items.map((item) => item.path).toList(),
            );
      final saved = await _saveDownloadedFile(payload);
      if (!mounted) return false;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('저장됨: ${saved.path.split('/').last}')),
      );
      await _openSavedFile(saved);
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('다운로드 실패: $e')));
      return false;
    }
  }

  Future<void> _downloadSelectedServerFiles() async {
    final items = _selectedServerFiles.values.toList()
      ..sort((a, b) => _compareNamesDesc(a.name, b.name));
    final success = await _downloadServerItems(items);
    if (mounted && success) _clearSelection();
  }

  /// 사용자가 명시적으로 '다른 앱으로 열기' 원할 때 (long-press) 또는
  /// OpenFilex 실패 시 fallback 으로 호출. share_plus 가 FileProvider 자동 설정.
  Future<void> _shareLocalFile(LocalFileEntry f) async {
    final name = f.name;
    try {
      await Share.shareXFiles([XFile(f.path)], subject: name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('공유 실패: $e')));
    }
  }

  Future<void> _shareSelectedLocalFiles() async {
    final files = _selectedLocalFiles.values.toList()
      ..sort((a, b) => _compareNamesDesc(a.name, b.name));
    if (files.isEmpty) return;
    try {
      await Share.shareXFiles(
        files.map((file) => XFile(file.path)).toList(),
        subject: files.length == 1 ? files.first.name : '${files.length}개 파일',
      );
      if (mounted) _clearSelection();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('공유 실패: $e')));
    }
  }

  void _deleteLocalFile(LocalFileEntry f) async {
    final name = f.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('파일 삭제'),
        content: Text('$name 을(를) 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await File(f.path).delete();
      if (mounted) _loadLocalFiles(_currentLocalPath);
    }
  }

  Future<void> _deleteSelectedLocalFiles() async {
    final files = _selectedLocalFiles.values.toList();
    if (files.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('파일 삭제'),
        content: Text('${files.length}개 파일을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    var deletedCount = 0;
    final errors = <String>[];
    for (final file in files) {
      try {
        await File(file.path).delete();
        deletedCount++;
      } catch (e) {
        errors.add('${file.name}: $e');
      }
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _clearSelection();
    await _loadLocalFiles(_currentLocalPath);
    final baseMessage = errors.isEmpty
        ? '$deletedCount개 파일을 삭제했습니다.'
        : '$deletedCount개 삭제, ${errors.length}개 실패';
    messenger.showSnackBar(SnackBar(content: Text(baseMessage)));
  }

  Future<void> _deleteSelectedServerFiles() async {
    final items = _selectedServerFiles.values.toList();
    if (items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('파일 삭제'),
        content: Text('${items.length}개 서버 파일을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final result = await _api.deleteFiles(
        items.map((item) => item.path).toList(),
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      _clearSelection();
      await _loadServer(_currentPath);
      final hasErrors = result.errors.isNotEmpty;
      final message = hasErrors
          ? '${result.deletedCount}개 삭제, ${result.errors.length}개 제외'
          : '${result.deletedCount}개 파일을 삭제했습니다.';
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
    }
  }

  void _handleServerFileTap(FileItem item) {
    if (_selectionMode) {
      _toggleServerSelection(item);
      return;
    }
    _showServerFileDetails(item);
  }

  void _handleServerFileLongPress(FileItem item) {
    _toggleServerSelection(item);
  }

  void _showServerFileDetails(FileItem item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  fileIconForName(item.name),
                  color: context.sr.textDisabled,
                  size: 24,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.name,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _detailRow('경로', item.path),
            _detailRow(
              '크기',
              item.size != null ? formatFileSize(item.size!) : '-',
            ),
            _detailRow('수정일', item.modified),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: Icon(Icons.download),
                label: const Text('다운로드'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _downloadServerItems([item]);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(color: context.sr.textSecondary, fontSize: 13),
          ),
        ),
        Expanded(child: Text(value, style: TextStyle(fontSize: 13))),
      ],
    ),
  );

  Widget _buildStandaloneBody() {
    final hasParent = _parentLocalPath != null;
    final displayPath = _localDisplayPath(
      _currentLocalPath.isEmpty ? _localRootPath : _currentLocalPath,
    );

    if (_localFiles.isEmpty) {
      final emptyMessage = _isLocalRoot
          ? '내보낸 파일이 없습니다.\n아래 버튼으로 Excel을 생성하세요.'
          : '이 폴더에는 파일이나 하위 폴더가 없습니다.';
      return LayoutBuilder(
        builder: (_, c) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Column(
              children: [
                _buildLocalPathCard(displayPath, hasParent: hasParent),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      emptyMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.sr.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final entries = _localFiles;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: entries.length + 1,
      itemBuilder: (context, index) => index == 0
          ? _buildLocalPathCard(displayPath, hasParent: hasParent)
          : _buildLocalEntry(entries[index - 1]),
    );
  }

  Widget _buildLocalPathCard(String displayPath, {required bool hasParent}) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.folder_open),
            title: const Text(
              '현재 위치',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(displayPath),
          ),
          if (hasParent) const Divider(height: 1),
          if (hasParent)
            ListTile(
              leading: Icon(Icons.arrow_upward_rounded),
              title: const Text('상위 폴더로 이동'),
              subtitle: Text(_localDisplayPath(_parentLocalPath!)),
              onTap: _selectionMode
                  ? null
                  : () => _loadLocalFiles(_parentLocalPath),
            ),
        ],
      ),
    );
  }

  Widget _buildLocalEntry(LocalFileEntry entity) {
    final name = entity.name;
    final modified = _modifiedFormat.format(entity.modified.toLocal());
    final isDirectory = entity.isDirectory;
    final isSelected = _selectedLocalFiles.containsKey(entity.path);

    if (isDirectory) {
      return ListTile(
        leading: Icon(
          Icons.folder_rounded,
          color: StatusTone.of(
            Colors.amber,
            brightness: Theme.of(context).brightness,
            surface: context.sr.surface,
          ).foreground,
        ),
        title: Text(name, style: TextStyle(fontSize: 13)),
        subtitle: Text(
          '폴더  ·  $modified',
          style: TextStyle(fontSize: 11, color: context.sr.textSecondary),
        ),
        trailing: Icon(Icons.chevron_right),
        onTap: _selectionMode ? null : () => _loadLocalFiles(entity.path),
      );
    }

    final sizeStr = formatFileSize(entity.size);
    return ListTile(
      selected: isSelected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      leading: Icon(
        _selectionMode && isSelected
            ? Icons.check_circle
            : fileIconForName(name),
        color: _selectionMode && isSelected
            ? Theme.of(context).colorScheme.primary
            : StatusTone.of(
                Colors.green,
                brightness: Theme.of(context).brightness,
                surface: context.sr.surface,
              ).foreground,
      ),
      title: Text(name, style: TextStyle(fontSize: 13)),
      subtitle: Text(
        '$sizeStr  ·  $modified  ·  길게 눌러 선택',
        style: TextStyle(fontSize: 11, color: context.sr.textSecondary),
      ),
      trailing: _selectionMode
          ? Icon(
              isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : context.sr.textDisabled,
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.share_outlined, size: 22),
                  tooltip: '다른 앱으로 열기 / 공유',
                  onPressed: () => _shareLocalFile(entity),
                ),
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () => _deleteLocalFile(entity),
                ),
              ],
            ),
      onTap: _selectionMode
          ? () => _toggleLocalSelection(entity)
          : () => _openLocalFile(entity),
      onLongPress: () => _toggleLocalSelection(entity),
    );
  }

  PreferredSizeWidget _buildStandaloneAppBar() {
    if (_selectionMode) {
      return AppBar(
        leading: IconButton(
          onPressed: _clearSelection,
          icon: Icon(Icons.close),
          tooltip: '선택 해제',
        ),
        title: Text('$_selectedCount개 선택됨'),
        actions: [
          IconButton(
            onPressed: _shareSelectedLocalFiles,
            tooltip: '공유',
            icon: Icon(Icons.share_outlined),
          ),
          IconButton(
            onPressed: _deleteSelectedLocalFiles,
            tooltip: '삭제',
            icon: Icon(Icons.delete_outline),
          ),
        ],
      );
    }
    return AppBar(title: const Text('파일 브라우저'));
  }

  Widget _buildStandalone() {
    return Scaffold(
      appBar: _buildStandaloneAppBar(),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: !_exporting
                  ? _exportExcel
                  : _exportCancel!.isCancelled
                  ? null
                  : _cancelExport,
              tooltip: _exporting ? '내보내기 취소' : null,
              icon: _exporting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: _exportProgress?.fraction,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    )
                  : Icon(Icons.file_download),
              label: Text(_exportLabel()),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorView(() => _loadLocalFiles(_currentLocalPath))
          : RefreshIndicator(
              onRefresh: () => _loadLocalFiles(_currentLocalPath),
              child: _buildStandaloneBody(),
            ),
    );
  }

  // ── 서버 모드 ────────────────────────────────────────────────────────────────

  Future<void> _loadServer(String path) async {
    _currentPath = path;
    setState(() {
      _loading = true;
      _error = null;
      _rootItems = null;
      _selectedServerFiles.clear();
    });
    try {
      final items = await _api.getFiles(path);
      items.sort((a, b) => _compareNamesDesc(a.name, b.name));
      if (mounted) {
        setState(() {
          _rootItems = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Widget _errorView(VoidCallback onRetry) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: Icon(Icons.refresh),
            label: const Text('다시 시도'),
            onPressed: onRetry,
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    _watchRefreshNonce(context);
    if (_isStandalone) return _buildStandalone();

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                onPressed: _clearSelection,
                icon: Icon(Icons.close),
                tooltip: '선택 해제',
              ),
              title: Text('$_selectedCount개 선택됨'),
              actions: [
                IconButton(
                  onPressed: _downloadSelectedServerFiles,
                  tooltip: '다운로드',
                  icon: Icon(Icons.download_outlined),
                ),
                IconButton(
                  onPressed: _deleteSelectedServerFiles,
                  tooltip: '삭제',
                  icon: Icon(Icons.delete_outline),
                ),
              ],
            )
          : AppBar(title: const Text('파일 브라우저')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorView(() => _loadServer(''))
          : RefreshIndicator(
              onRefresh: () => _loadServer(''),
              child: ListView.builder(
                itemCount: _rootItems?.length ?? 0,
                itemBuilder: (context, i) => _TreeNode(
                  item: _rootItems![i],
                  api: _api,
                  depth: 0,
                  selectionMode: _selectionMode,
                  isSelectedPath: _selectedServerFiles.containsKey,
                  onFileTap: _handleServerFileTap,
                  onFileLongPress: _handleServerFileLongPress,
                ),
              ),
            ),
    );
  }
}

// ──────────────────────────────────────────────
class _TreeNode extends StatefulWidget {
  final FileItem item;
  final ApiService api;
  final int depth;
  final bool selectionMode;
  final bool Function(String path) isSelectedPath;
  final ValueChanged<FileItem> onFileTap;
  final ValueChanged<FileItem> onFileLongPress;

  const _TreeNode({
    required this.item,
    required this.api,
    required this.depth,
    required this.selectionMode,
    required this.isSelectedPath,
    required this.onFileTap,
    required this.onFileLongPress,
  });

  @override
  State<_TreeNode> createState() => _TreeNodeState();
}

class _TreeNodeState extends State<_TreeNode> {
  bool _expanded = false;
  bool _loading = false;
  List<FileItem>? _children;

  Future<void> _toggle() async {
    if (!widget.item.isDir) {
      widget.onFileTap(widget.item);
      return;
    }
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    if (_children != null) {
      setState(() => _expanded = true);
      return;
    }

    setState(() => _loading = true);
    try {
      final items = await widget.api.getFiles(widget.item.path);
      items.sort(
        (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()),
      );
      if (mounted) {
        setState(() {
          _children = items;
          _expanded = true;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('오류: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final indent = widget.depth * 20.0;
    final isSelected = widget.isSelectedPath(item.path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: item.isDir ? _toggle : () => widget.onFileTap(item),
          onLongPress: item.isDir ? null : () => widget.onFileLongPress(item),
          child: Padding(
            padding: EdgeInsets.only(
              left: 16 + indent,
              right: 12,
              top: 10,
              bottom: 10,
            ),
            child: Row(
              children: [
                // 트리 라인 표시
                if (widget.depth > 0) ...[
                  SizedBox(width: 4),
                  Icon(
                    Icons.subdirectory_arrow_right,
                    size: 14,
                    color: context.sr.textDisabled,
                  ),
                  const SizedBox(width: 4),
                ],
                // 아이콘
                _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        item.isDir
                            ? (_expanded ? Icons.folder_open : Icons.folder)
                            : widget.selectionMode && isSelected
                            ? Icons.check_circle
                            : fileIconForName(item.name),
                        color: item.isDir
                            ? StatusTone.of(
                                serverPartialAcceptColor,
                                brightness: Theme.of(context).brightness,
                                surface: context.sr.surface,
                              ).foreground
                            : widget.selectionMode && isSelected
                            ? Theme.of(context).colorScheme.primary
                            : context.sr.textDisabled,
                        size: 20,
                      ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: item.isDir
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (!item.isDir && item.size != null)
                  Text(
                    formatFileSize(item.size!),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.sr.textSecondary,
                    ),
                  ),
                if (!item.isDir)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      item.modified,
                      style: TextStyle(
                        fontSize: 10,
                        color: context.sr.textSecondary,
                      ),
                    ),
                  ),
                if (!item.isDir && widget.selectionMode)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : context.sr.textDisabled,
                    ),
                  ),
                if (item.isDir)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: context.sr.textSecondary,
                  ),
              ],
            ),
          ),
        ),
        if (_expanded && _children != null)
          ..._children!.map(
            (child) => _TreeNode(
              item: child,
              api: widget.api,
              depth: widget.depth + 1,
              selectionMode: widget.selectionMode,
              isSelectedPath: widget.isSelectedPath,
              onFileTap: widget.onFileTap,
              onFileLongPress: widget.onFileLongPress,
            ),
          ),
        Divider(height: 1, indent: 16 + indent, color: context.sr.border),
      ],
    );
  }
}
