import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/app_mode.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/raw_detail.dart';
import '../theme/sr_colors.dart';
import '../widgets/sr_snack_bar.dart';

/// 들여쓰기 2칸 고정폭 JSON(사람이 보는 사본·원본 보기 화면 공용 형식).
/// 서버 `<datapath>/raw_details/<ID>.json`, 모바일
/// `Documents/mysafetyreport/raw_details/<ID>.json` 과 같은 직렬화다.
@visibleForTesting
String prettyRawJson(Map<String, dynamic> json) =>
    const JsonEncoder.withIndent('  ').convert(json);

/// 원본 보기 줄 한 개의 대략 높이(고정폭 12pt·줄간격 1.5 → 18 + 여유).
/// 화면 밖 일치로 이동할 때 줄 번호 × 이 값으로 먼저 점프한다(지연 생성 목록 대응).
@visibleForTesting
const estimatedRawLineHeight = 20.0;

/// 검색 일치 위치(줄 번호·줄 안 시작·끝, 대소문자 무시).
@visibleForTesting
class RawMatch {
  final int line;
  final int start;
  final int end;

  const RawMatch(this.line, this.start, this.end);
}

/// [lines] 에서 [query]가 나오는 모든 위치. 빈 검색이면 빈 목록.
@visibleForTesting
List<RawMatch> findRawMatches(List<String> lines, String query) {
  if (query.isEmpty) return const [];
  final needle = query.toLowerCase();
  final out = <RawMatch>[];
  for (var i = 0; i < lines.length; i++) {
    final hay = lines[i].toLowerCase();
    var from = 0;
    while (true) {
      final at = hay.indexOf(needle, from);
      if (at < 0) break;
      out.add(RawMatch(i, at, at + needle.length));
      from = at + (needle.isEmpty ? 1 : needle.length);
    }
  }
  return out;
}

/// 원본 응답 1건(화면 표시용).
class RawDetailData {
  final String pretty;
  final Map<String, dynamic> sanitized;
  final String fetchedAt;
  final String source;
  final String sha256;

  const RawDetailData({
    required this.pretty,
    required this.sanitized,
    this.fetchedAt = '',
    this.source = '',
    this.sha256 = '',
  });
}

/// 원본 보기 화면의 입출력 경계(시험은 가짜를 끼운다).
/// 로드 실패는 [RawDetailMissing](없음)·[RawDetailCorrupt](손상)로 알리고,
/// 그 밖의 예외(네트워크 등)는 그대로 던진다(화면에서 재시도).
abstract class RawDetailSource {
  bool get isStandalone;

  /// 시험 주입용 경계. null 이면 Provider(모드·서버 설정)에서 실제 경계를 만든다.
  /// source 를 주입하지 않는 실제 진입 경로 시험에서 쓴다.
  @visibleForTesting
  static RawDetailSource? debugSourceOverride;

  factory RawDetailSource.of(BuildContext context) {
    final test = debugSourceOverride;
    if (test != null) return test;
    final p = context.read<ReportProvider>();
    if (p.appMode == AppMode.standalone) return StandaloneRawDetailSource();
    return ClientRawDetailSource(baseUrl: p.baseUrl, apiKey: p.apiKey);
  }

  Future<RawDetailData> load(String reportId);
  Future<String?> rewriteFile(String reportId, Map<String, dynamic> sanitized);
  Future<void> shareFile(String reportId, String pretty);
}

/// Standalone: 로컬 `report_detail_raw` 에서 읽는다(zlib 해제·sha 검증).
/// "파일로 다시 쓰기"는 DB 원본으로 `.../raw_details/<ID>.json` 을 재생성한다.
class StandaloneRawDetailSource implements RawDetailSource {
  @override
  bool get isStandalone => true;

  @override
  Future<RawDetailData> load(String reportId) async {
    final row = await LocalDbService.getDetailRaw(reportId);
    if (row == null) throw const RawDetailMissing();
    final blob = row['raw_zlib'];
    final sha = row['raw_sha256']?.toString() ?? '';
    if (blob is! Uint8List) throw const RawDetailCorrupt();
    late Uint8List canonical;
    try {
      canonical = decompressAndVerifyRawDetail(blob, sha);
    } on StateError {
      throw const RawDetailCorrupt();
    }
    late Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(canonical));
      if (decoded is! Map) throw const FormatException('not an object');
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw const RawDetailCorrupt();
    }
    return RawDetailData(
      pretty: prettyRawJson(json),
      sanitized: json,
      fetchedAt: row['fetched_at']?.toString() ?? '',
      source: row['source']?.toString() ?? '',
      sha256: sha,
    );
  }

  @override
  Future<String?> rewriteFile(
    String reportId,
    Map<String, dynamic> sanitized,
  ) => writeRawDetailFile(reportId, sanitized);

  @override
  Future<void> shareFile(String reportId, String pretty) =>
      sharePrettyRawJson(reportId, pretty);
}

/// Client: 서버 `GET /api/v1/reports/{id}/raw-detail` 에서 읽는다.
/// 파일 쓰기는 서버 웹의 파일 탐색기가 맡으므로 지원하지 않는다.
class ClientRawDetailSource implements RawDetailSource {
  final String baseUrl;
  final String apiKey;

  ClientRawDetailSource({required this.baseUrl, required this.apiKey});

  /// 시험용 서버 응답 훅(Client 가짜 API). null 이면 실제 서버를 부른다.
  @visibleForTesting
  static Future<RawDetailData> Function(
    String baseUrl,
    String apiKey,
    String reportId,
  )?
  debugLoadOverride;

  @override
  bool get isStandalone => false;

  @override
  Future<RawDetailData> load(String reportId) async {
    final hook = debugLoadOverride;
    if (hook != null) return hook(baseUrl, apiKey, reportId);
    final payload = await ApiService(
      baseUrl: baseUrl,
      apiKey: apiKey,
    ).fetchRawDetail(reportId);
    return RawDetailData(
      pretty: prettyRawJson(payload.json),
      sanitized: payload.json,
      fetchedAt: payload.fetchedAt,
      source: payload.source,
      sha256: payload.sha256,
    );
  }

  @override
  Future<String?> rewriteFile(
    String reportId,
    Map<String, dynamic> sanitized,
  ) async {
    throw UnsupportedError('Client 모드에서는 파일을 다시 쓸 수 없습니다.');
  }

  @override
  Future<void> shareFile(String reportId, String pretty) =>
      sharePrettyRawJson(reportId, pretty);
}

/// 공유용 `<ID>.json` 임시 파일을 만들어 다른 앱으로 공유한다.
/// ID 검증 규칙([isSafeReportId])을 유지한다 — 어기면 쓰지 않고 던진다.
/// 공유가 끝나면(성공·취소·실패 모두) 임시 파일을 지운다.
Future<void> sharePrettyRawJson(String reportId, String pretty) async {
  if (!isSafeReportId(reportId)) {
    throw StateError('공유할 수 없는 신고 ID입니다: $reportId');
  }
  final dir = await _shareTempDir();
  final file = File('${dir.path}/$reportId.json');
  await file.writeAsString(pretty, encoding: utf8);
  try {
    final params = ShareParams(
      files: [XFile(file.path)],
      subject: '$reportId.json',
    );
    final hook = debugRawShareHook;
    if (hook != null) {
      await hook(params);
    } else {
      await SharePlus.instance.share(params);
    }
  } finally {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// 공유 뒤 임시 디렉터리에 남은 `<ID>.json` 을 지운다(공유 취소·실패 뒤 잔여분,
/// 화면을 떠날 때 남은 파일 정리용). 없으면 아무 것도 안 한다.
@visibleForTesting
Future<void> cleanupRawShareTempFile(String reportId) async {
  if (!isSafeReportId(reportId)) return;
  try {
    final dir = await _shareTempDir();
    final file = File('${dir.path}/$reportId.json');
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

Future<Directory> _shareTempDir() async {
  final override = debugRawShareTempDir;
  if (override != null) return override();
  return getTemporaryDirectory();
}

/// 시험용 임시 디렉터리 훅. null 이면 실제 [getTemporaryDirectory] 를 쓴다.
@visibleForTesting
Future<Directory> Function()? debugRawShareTempDir;

/// 시험용 공유 훅. null 이면 실제 공유 시트를 띄운다.
@visibleForTesting
Future<ShareResult> Function(ShareParams params)? debugRawShareHook;

/// 신고 상세 시트의 "원본 응답" 동작 → 전체 화면 JSON 보기(명세 4절, 모바일).
/// 고정폭·들여쓰기 2칸, 검색(일치 강조·다음·이전·건수), 전체 복사·공유,
/// 가로 스크롤 없이 줄바꿈한다(긴 본문 문자열 고려). 360px·라이트·다크·접근성 대응.
class RawDetailViewScreen extends StatefulWidget {
  final String reportId;

  /// 시험 주입용. null 이면 Provider(모드·서버 설정)에서 실제 경계를 만든다.
  final RawDetailSource? source;

  /// 시험 주입용 복사 훅. null 이면 [Clipboard]에 둔다.
  @visibleForTesting
  static Future<void> Function(String text)? copyOverride;

  const RawDetailViewScreen({super.key, required this.reportId, this.source});

  @override
  State<RawDetailViewScreen> createState() => _RawDetailViewScreenState();
}

class _RawDetailViewScreenState extends State<RawDetailViewScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _currentKey = GlobalKey();

  RawDetailSource? _source;

  /// 소스가 정해져 첫 불러오기를 시작했는가. 주입이 없으면
  /// [didChangeDependencies] 에서 Provider 로 정한 뒤 시작한다.
  bool _sourceResolved = false;
  bool _loading = true;
  RawDetailData? _data;
  bool _missing = false;
  bool _corrupt = false;
  String? _error;
  List<RawMatch> _matches = const [];
  int _current = -1;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    // 주입이 있으면 바로 불러온다. 없으면 didChangeDependencies 에서
    // 실제 진입 경로(Provider·모드)로 소스를 정한 뒤 불러온다 — initState 에서
    // 미리 불러오면 소스가 null 이라 오류 화면이 뜬다.
    if (widget.source != null) {
      _source = widget.source;
      _sourceResolved = true;
      _load();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sourceResolved) return;
    _source = widget.source ?? RawDetailSource.of(context);
    _sourceResolved = true;
    _load();
  }

  @override
  void didUpdateWidget(RawDetailViewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reportId != widget.reportId ||
        oldWidget.source != widget.source) {
      // 위젯 교체로는 didChangeDependencies 가 다시 불리지 않아 여기서 정한다.
      _source = widget.source ?? RawDetailSource.of(context);
      _sourceResolved = true;
      _load();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    // 공유 뒤 남은 임시 `<ID>.json` 이 있으면 지운다.
    unawaited(cleanupRawShareTempFile(widget.reportId));
    super.dispose();
  }

  RawDetailSource get _src => widget.source ?? _source!;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _missing = false;
      _corrupt = false;
      _error = null;
    });
    try {
      final data = await _src.load(widget.reportId);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
      _onSearchChanged();
    } on RawDetailMissing {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _missing = true;
      });
    } on RawDetailCorrupt {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _corrupt = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _onSearchChanged() {
    final data = _data;
    if (data == null) return;
    final matches = findRawMatches(
      data.pretty.split('\n'),
      _searchController.text,
    );
    setState(() {
      _matches = matches;
      _current = matches.isEmpty ? -1 : 0;
    });
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _current = (_current + delta) % _matches.length;
      if (_current < 0) _current += _matches.length;
    });
    _revealCurrent(attempt: 0);
  }

  /// 현재 일치를 화면에 보이게 한다. 수천 줄 JSON 에서는 대상 줄이 지연 생성
  /// 목록 밖에 있어 키가 없을 수 있다 — 그때는 실측 평균 줄 높이로 어림한
  /// 위치로 먼저 점프해 줄을 만든 뒤 맞춘다. 어림이 빗나가면 화면 크기만큼씩
  /// 다가가며 바로잡는다(최대 10번).
  void _revealCurrent({required int attempt}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _matches.isEmpty || !_scrollController.hasClients) return;
      final ctx = _currentKey.currentContext;
      if (ctx != null) {
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 200),
            alignment: 0.3,
          ),
        );
        return;
      }
      if (attempt >= 10) return;
      final pos = _scrollController.position;
      final totalLines = _data?.pretty.split('\n').length ?? 0;
      var perLine = estimatedRawLineHeight;
      if (totalLines > 1 &&
          pos.maxScrollExtent > 0 &&
          pos.viewportDimension > 0) {
        perLine = (pos.maxScrollExtent + pos.viewportDimension) / totalLines;
      }
      final target = (_matches[_current].line * perLine)
          .clamp(0.0, pos.maxScrollExtent)
          .toDouble();
      final double next;
      if (attempt == 0) {
        // 첫 시도는 어림 위치로 직접 — 화면 단위 이동만으로는 수천 줄을 못 간다.
        next = target;
      } else {
        final gap = target - pos.pixels;
        next = gap.abs() <= pos.viewportDimension
            ? target
            : pos.pixels + pos.viewportDimension * 0.9 * gap.sign;
      }
      _scrollController.jumpTo(next.clamp(0.0, pos.maxScrollExtent).toDouble());
      _revealCurrent(attempt: attempt + 1);
    });
  }

  Future<void> _copyAll() async {
    final text = _data?.pretty;
    if (text == null) return;
    final copy = RawDetailViewScreen.copyOverride;
    if (copy != null) {
      await copy(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (!mounted) return;
    showSrSnack(context, '원본 JSON을 복사했습니다.');
  }

  Future<void> _share() async {
    final text = _data?.pretty;
    if (text == null) return;
    try {
      await _src.shareFile(widget.reportId, text);
    } catch (e) {
      if (!mounted) return;
      showSrSnack(context, '공유 실패: $e', kind: SrSnackKind.error);
    }
  }

  Future<void> _rewrite() async {
    final data = _data;
    if (data == null) return;
    try {
      final path = await _src.rewriteFile(widget.reportId, data.sanitized);
      if (!mounted) return;
      if (path == null) {
        showSrSnack(
          context,
          '파일로 다시 쓸 수 없는 신고 ID입니다.',
          kind: SrSnackKind.error,
        );
        return;
      }
      showSrSnack(
        context,
        '원본 파일을 다시 썼습니다: ${path.split('/').last}',
        kind: SrSnackKind.success,
      );
    } catch (e) {
      if (!mounted) return;
      showSrSnack(context, '다시 쓰기 실패: $e', kind: SrSnackKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('원본 응답'),
        actions: [
          if (_data != null)
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: '전체 복사',
              onPressed: _copyAll,
            ),
          if (_data != null)
            IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: '공유',
              onPressed: _share,
            ),
        ],
      ),
      body: _buildBody(context, scheme),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_missing) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '아직 원본이 없습니다(DB 최적화가 채웁니다)',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14),
          ),
        ),
      );
    }
    if (_corrupt) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '저장된 원본이 손상되어 보여줄 수 없습니다.\n다음 DB 최적화에서 다시 받으면 볼 수 있습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14),
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '원본을 불러오지 못했습니다.\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
                onPressed: _load,
              ),
            ],
          ),
        ),
      );
    }
    final data = _data!;
    final lines = data.pretty.split('\n');
    final byLine = <int, List<RawMatch>>{};
    for (final m in _matches) {
      (byLine[m.line] ??= []).add(m);
    }
    final query = _searchController.text;
    final countLabel = query.isEmpty
        ? '검색어를 입력하세요'
        : _matches.isEmpty
        ? '일치 없음'
        : '${_matches.length}개 중 ${_current + 1}번째';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: '검색',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward),
                tooltip: '이전 일치',
                onPressed: _matches.isEmpty ? null : () => _step(-1),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward),
                tooltip: '다음 일치',
                onPressed: _matches.isEmpty ? null : () => _step(1),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              countLabel,
              semanticsLabel: query.isEmpty
                  ? '검색 일치 없음'
                  : _matches.isEmpty
                  ? '검색 일치 없음'
                  : '검색 일치 ${_matches.length}개 중 ${_current + 1}번째',
              style: TextStyle(
                fontSize: 12,
                color: context.sr.textSecondary,
              ),
            ),
          ),
        ),
        if (data.fetchedAt.isNotEmpty || data.source.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                [
                  if (data.fetchedAt.isNotEmpty) '받은 시각 ${data.fetchedAt}',
                  if (data.source.isNotEmpty) '출처 ${data.source}',
                ].join(' · '),
                style: TextStyle(
                  fontSize: 12,
                  color: context.sr.textSecondary,
                ),
              ),
            ),
          ),
        if (_src.isStandalone)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('파일로 다시 쓰기'),
                onPressed: _rewrite,
              ),
            ),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final lineMatches = byLine[i];
              final isCurrentLine =
                  _current >= 0 && _matches[_current].line == i;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${i + 1}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: context.sr.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _lineText(
                      context,
                      scheme,
                      lines[i],
                      lineMatches,
                      isCurrent: isCurrentLine,
                      current: _current >= 0 ? _matches[_current] : null,
                      key: isCurrentLine ? _currentKey : null,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _lineText(
    BuildContext context,
    ColorScheme scheme,
    String line,
    List<RawMatch>? matches, {
    required bool isCurrent,
    required RawMatch? current,
    Key? key,
  }) {
    const style = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5);
    if (matches == null || matches.isEmpty) {
      return SelectableText(line, key: key, style: style);
    }
    final spans = <TextSpan>[];
    var pos = 0;
    final sorted = List<RawMatch>.of(matches)
      ..sort((a, b) => a.start.compareTo(b.start));
    for (final m in sorted) {
      if (m.start > pos) {
        spans.add(TextSpan(text: line.substring(pos, m.start)));
      }
      final isCurrentMatch =
          isCurrent && current != null && current.start == m.start;
      spans.add(
        TextSpan(
          text: line.substring(m.start, m.end),
          style: TextStyle(
            backgroundColor: isCurrentMatch
                ? scheme.primary
                : scheme.primary.withValues(alpha: 0.3),
            color: isCurrentMatch ? scheme.onPrimary : null,
            fontWeight: isCurrentMatch ? FontWeight.bold : null,
          ),
        ),
      );
      pos = m.end;
    }
    if (pos < line.length) {
      spans.add(TextSpan(text: line.substring(pos)));
    }
    return SelectableText.rich(
      TextSpan(style: style, children: spans),
      key: key,
    );
  }
}