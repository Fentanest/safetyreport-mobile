import 'dart:io';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../models/app_mode.dart';
import '../models/file_item.dart';
import '../models/report.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';

class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

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

  // standalone mode state
  List<FileSystemEntity> _localFiles = [];
  bool _exporting = false;

  bool _loading = true;
  late final bool _isStandalone;

  @override
  void initState() {
    super.initState();
    _isStandalone = Provider.of<ReportProvider>(context, listen: false).appMode ==
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

  // ── 스탠드어론 ─────────────────────────────────────────────────────────────

  Future<Directory> _exportsDir() async {
    final dir = Directory('/storage/emulated/0/Documents/mysafetyreport');
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (_) {
        // Fallback for some devices that restrict Documents creation
        final altDir = Directory('/storage/emulated/0/Download/mysafetyreport');
        if (!altDir.existsSync()) altDir.createSync(recursive: true);
        return altDir;
      }
    }
    return dir;
  }

  Future<void> _loadLocalFiles() async {
    setState(() { _loading = true; _error = null; });
    try {
      final dir = await _exportsDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      if (mounted) setState(() { _localFiles = files; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _exportExcel() async {
    if (_exporting) return;
    
    // 권한 요청 (안드로이드 10 이하용, 11 이상은 Documents 쓰기 기본 허용인 경우 많음)
    if (Platform.isAndroid) {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        await Permission.storage.request();
      }
    }

    setState(() => _exporting = true);

    try {
      final tReports = await LocalDbService.getReportsByCategory('traffic');
      final pReports = await LocalDbService.getReportsByCategory('parking');
      final oReports = await LocalDbService.getReportsByCategory('other');
      final watchlist = await LocalDbService.getWatchlistNumbers();

      final excel = Excel.createExcel();
      _fillSheet(excel, '교통위반', tReports, watchlist);
      _fillSheet(excel, '주정차위반', pReports, watchlist);
      _fillSheet(excel, '기타위반', oReports, watchlist);
      // remove default sheet
      excel.delete('Sheet1');

      final dir = await _exportsDir();
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final path = '${dir.path}/안전신문고_$ts.xlsx';
      final bytes = excel.encode();
      if (bytes == null) throw Exception('Excel 인코딩 실패');
      await File(path).writeAsBytes(bytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장됨: 안전신문고_$ts.xlsx')),
        );
        await _loadLocalFiles();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('내보내기 실패: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _fillSheet(Excel excel, String sheetName, List<Report> reports, Set<String> watchlist) {
    final sheet = excel[sheetName];

    // 첨부사진/첨부파일 URL 목록 분리
    final photoLists = reports
        .map((r) => r.attachedPhotos.isEmpty
            ? <String>[]
            : r.attachedPhotos.split('\n').where((s) => s.trim().isNotEmpty).toList())
        .toList();
    final fileLists = reports
        .map((r) => r.attachedFiles.isEmpty
            ? <String>[]
            : r.attachedFiles.split('\n').where((s) => s.trim().isNotEmpty).toList())
        .toList();

    final maxPhotos = photoLists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    final maxFiles = fileLists.fold<int>(0, (m, l) => l.length > m ? l.length : m);

    // 서버 export.py 컬럼 순서: original_cols + 지도 + 첨부사진N + 첨부파일N + 만족도조사여부 + 감시목록
    final headers = <String>[
      'ID', '상태', '신고번호', '신고명', '신고일',
      '처리상태', '차량번호', '위반법규', '범칙금_과태료', '벌점',
      '처리기관', '담당자', '답변일', '발생일자', '발생시각', '위반장소',
      '종결여부', '신고내용', '처리내용', '지도',
      for (var i = 1; i <= maxPhotos; i++) '첨부사진$i',
      for (var i = 1; i <= maxFiles; i++) '첨부파일$i',
      '만족도조사여부', '감시목록',
    ];

    for (var col = 0; col < headers.length; col++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0))
          .value = TextCellValue(headers[col]);
    }

    for (var row = 0; row < reports.length; row++) {
      final r = reports[row];
      final photos = photoLists[row];
      final files = fileLists[row];
      final values = <String>[
        r.id, r.result, r.reportNumber, r.name, r.date,
        r.status, r.carNumber, r.law, r.fineInfo, r.penaltyPoints,
        r.agency, r.manager, r.responseDate, r.occurrenceDate, r.occurrenceTime, r.location,
        r.processingFinish, r.reportContent, r.processContent, r.mapImage,
        for (var i = 0; i < maxPhotos; i++) i < photos.length ? photos[i] : '',
        for (var i = 0; i < maxFiles; i++) i < files.length ? files[i] : '',
        r.pollStatus,
        watchlist.contains(r.reportNumber) ? 'Y' : 'N',
      ];
      for (var col = 0; col < values.length; col++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row + 1))
            .value = TextCellValue(values[col]);
      }
    }
  }

  void _openLocalFile(FileSystemEntity f) async {
    final result = await OpenFilex.open(f.path);
    if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('열 수 있는 앱이 없습니다: ${f.path.split('/').last}')),
      );
    }
  }

  void _deleteLocalFile(FileSystemEntity f) async {
    final name = f.path.split('/').last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('파일 삭제'),
        content: Text('$name 을(를) 삭제하시겠습니까?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) {
      f.deleteSync();
      _loadLocalFiles();
    }
  }

  Widget _buildStandalone() {
    return Scaffold(
      appBar: AppBar(title: const Text('파일 브라우저')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _exporting ? null : _exportExcel,
        icon: _exporting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.file_download),
        label: Text(_exporting ? '내보내는 중...' : 'Excel 내보내기'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView(() => _loadLocalFiles())
              : RefreshIndicator(
                  onRefresh: _loadLocalFiles,
                  child: _localFiles.isEmpty
                      ? LayoutBuilder(
                          builder: (_, c) => SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: ConstrainedBox(
                              constraints:
                                  BoxConstraints(minHeight: c.maxHeight),
                              child: const Center(
                                child: Text('내보낸 파일이 없습니다.\n아래 버튼으로 Excel을 생성하세요.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: Colors.grey, fontSize: 14)),
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _localFiles.length,
                          itemBuilder: (_, i) {
                            final f = _localFiles[i];
                            final name = f.path.split('/').last;
                            final stat = f.statSync();
                            final size = stat.size;
                            final modified = DateFormat('yy/MM/dd HH:mm')
                                .format(stat.modified.toLocal());
                            final sizeStr = size < 1024 * 1024
                                ? '${(size / 1024).toStringAsFixed(1)} KB'
                                : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
                            return ListTile(
                              leading: const Icon(Icons.table_chart,
                                  color: Colors.green),
                              title: Text(name,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text('$sizeStr  ·  $modified',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600)),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.red),
                                onPressed: () => _deleteLocalFile(f),
                              ),
                              onTap: () => _openLocalFile(f),
                            );
                          },
                        ),
                ),
    );
  }

  // ── 서버 모드 ────────────────────────────────────────────────────────────────

  Future<void> _loadServer(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _rootItems = null;
    });
    try {
      final items = await _api.getFiles(path);
      if (mounted) setState(() { _rootItems = items; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Widget _errorView(VoidCallback onRetry) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_isStandalone) return _buildStandalone();

    return Scaffold(
      appBar: AppBar(title: const Text('파일 브라우저')),
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
                      baseUrl: _baseUrl,
                      apiKey: _apiKey,
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
  final String baseUrl;
  final String apiKey;

  const _TreeNode({
    required this.item,
    required this.api,
    required this.depth,
    required this.baseUrl,
    required this.apiKey,
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
      _showDetails();
      return;
    }
    if (_expanded) { setState(() => _expanded = false); return; }
    if (_children != null) { setState(() => _expanded = true); return; }

    setState(() => _loading = true);
    try {
      final items = await widget.api.getFiles(widget.item.path);
      if (mounted) setState(() { _children = items; _expanded = true; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('오류: $e')));
      }
    }
  }

  Future<void> _download(BuildContext ctx, FileItem item) async {
    final downloadUri = Uri.parse(widget.baseUrl)
        .replace(path: '/api/v1/files/download')
        .replace(queryParameters: {'path': item.path});

    ScaffoldMessenger.of(ctx).showSnackBar(
      const SnackBar(content: Text('다운로드 중...'), duration: Duration(seconds: 30)),
    );

    try {
      final response = await http.get(downloadUri, headers: {'X-API-Key': widget.apiKey});
      if (response.statusCode != 200) {
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(content: Text('다운로드 실패: ${response.statusCode}')),
          );
        }
        return;
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${item.name}');
      await file.writeAsBytes(response.bodyBytes);

      if (ctx.mounted) ScaffoldMessenger.of(ctx).hideCurrentSnackBar();

      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('열 수 있는 앱이 없습니다: ${item.name}')),
        );
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('오류: $e')),
        );
      }
    }
  }

  void _showDetails() {
    final item = widget.item;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Icon(_fileIcon(item.name), color: Colors.blueGrey, size: 24),
              const SizedBox(width: 10),
              Expanded(child: Text(item.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            ]),
            const Divider(height: 24),
            _row('경로', item.path),
            _row('크기', item.size != null ? _fmt(item.size!) : '-'),
            _row('수정일', item.modified),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('다운로드'),
                onPressed: () => _download(ctx, item),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 56,
            child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'db': return Icons.storage;
      case 'log': return Icons.article;
      case 'csv': return Icons.table_chart;
      case 'xlsx': case 'xls': return Icons.table_chart;
      case 'json': return Icons.data_object;
      case 'txt': return Icons.text_snippet;
      case 'ini': return Icons.settings;
      case 'png': case 'jpg': case 'jpeg': return Icons.image;
      default: return Icons.insert_drive_file;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final indent = widget.depth * 20.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: EdgeInsets.only(left: 16 + indent, right: 12, top: 10, bottom: 10),
            child: Row(
              children: [
                // 트리 라인 표시
                if (widget.depth > 0) ...[
                  SizedBox(width: 4),
                  Icon(Icons.subdirectory_arrow_right, size: 14, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                ],
                // 아이콘
                _loading
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(
                        item.isDir
                            ? (_expanded ? Icons.folder_open : Icons.folder)
                            : _fileIcon(item.name),
                        color: item.isDir ? Colors.amber.shade700 : Colors.blueGrey,
                        size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(item.name,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: item.isDir ? FontWeight.w600 : FontWeight.normal)),
                ),
                if (!item.isDir && item.size != null)
                  Text(_fmt(item.size!),
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                if (!item.isDir)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(item.modified,
                        style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ),
                if (item.isDir)
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: Colors.grey),
              ],
            ),
          ),
        ),
        if (_expanded && _children != null)
          ..._children!.map((child) => _TreeNode(
              item: child, api: widget.api, depth: widget.depth + 1,
              baseUrl: widget.baseUrl, apiKey: widget.apiKey)),
        Divider(height: 1, indent: 16 + indent, color: Colors.grey.shade100),
      ],
    );
  }
}
