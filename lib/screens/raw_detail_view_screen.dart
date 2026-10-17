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
/// 검색 이동의 첫 점프 씨앗에만 쓰고(줄 번호 비율), 반복 어림에는 쓰지 않는다 —
/// 줄 높이가 크게 다르면 평균 반복이 수렴하지 않는다. 시험 호환용으로 남긴다.
@visibleForTesting
const estimatedRawLineHeight = 20.0;

/// 검색 일치로 좁혀 가는 최대 시도(화소 구간 이분 탐색 한 사이클씩 센다).
@visibleForTesting
const maxRawRevealAttempts = 40;

/// 한 사이클에 전체 높이가 이 배율을 넘겨 뛰면 지연 목록의 어림 깨짐으로 보고
/// 구간에 들이지 않는다(긴 줄 하나가 처음 배치되면 실제 증가분과 무관하게
/// 수십~수백 배까지 뛴다).
const _maxSaneGrowthRatio = 4.0;

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

/// 진행 중인 공유가 쓰는 임시 하위 폴더 경로들. 화면 종료 정리 때 건드리지 않는다.
final Set<String> _activeRawShareDirs = <String>{};
int _rawShareSeq = 0;

/// 공유용 `<ID>.json` 임시 파일을 만들어 다른 앱으로 공유한다.
/// ID 검증 규칙([isSafeReportId])을 유지한다 — 어기면 쓰지 않고 던진다.
/// 공유마다 고유 하위 폴더를 두어 같은 화면에서 공유를 겹쳐 시작해도 서로 파일을
/// 덮거나 지우지 않게 한다. 공유되는 파일 이름 자체는 `<ID>.json` 그대로(받는 쪽
/// 표시) — 하위 폴더별로 분리한다. 공유가 끝나면(성공·취소·실패 모두) 자기 파일·
/// 폴더만 지운다.
Future<void> sharePrettyRawJson(String reportId, String pretty) async {
  if (!isSafeReportId(reportId)) {
    throw StateError('공유할 수 없는 신고 ID입니다: $reportId');
  }
  final dir = await _shareTempDir();
  final shareDir = Directory(
    '${dir.path}/raw_share_${reportId}_${DateTime.now().microsecondsSinceEpoch}_${_rawShareSeq++}',
  );
  await shareDir.create(recursive: true);
  _activeRawShareDirs.add(shareDir.path);
  final file = File('${shareDir.path}/$reportId.json');
  final write = debugRawShareFileWrite;
  if (write != null) {
    await write(file, pretty);
  } else {
    await file.writeAsString(pretty, encoding: utf8);
  }
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
    _activeRawShareDirs.remove(shareDir.path);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    try {
      if (await shareDir.exists() && await shareDir.list().isEmpty) {
        await shareDir.delete();
      }
    } catch (_) {}
  }
}

/// 공유 뒤 임시 디렉터리에 남은 `<ID>.json` 을 지운다(공유 취소·실패 뒤 잔여분,
/// 화면을 떠날 때 남은 파일 정리용). 진행 중인 공유의 하위 폴더는 건드리지 않고,
/// 예전 평면 경로(바로 아래 `<ID>.json` — 새 공유는 만들지 않음)의 잔여분도 지운다.
/// 없으면 아무 것도 안 한다.
@visibleForTesting
Future<void> cleanupRawShareTempFile(String reportId) async {
  if (!isSafeReportId(reportId)) return;
  try {
    final dir = await _shareTempDir();
    if (!await dir.exists()) return;
    final flat = File('${dir.path}/$reportId.json');
    if (await flat.exists()) {
      try {
        await flat.delete();
      } catch (_) {}
    }
    final prefix = '${dir.path}/raw_share_${reportId}_';
    await for (final e in dir.list()) {
      if (e is! Directory || !e.path.startsWith(prefix)) continue;
      if (_activeRawShareDirs.contains(e.path)) continue;
      final f = File('${e.path}/$reportId.json');
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
      try {
        if (await e.exists() && await e.list().isEmpty) {
          await e.delete();
        }
      } catch (_) {}
    }
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

/// 시험용 공유 파일 쓰기 훅. null 이면 실제 파일에 쓴다.
/// 쓰기 실패 시 정리(임시 폴더·활성 경로 기록)를 시험할 때 주입한다.
@visibleForTesting
Future<void> Function(File file, String content)? debugRawShareFileWrite;

/// 진행 중인 공유 하위 폴더로 기록됐는지 시험에서 확인한다.
@visibleForTesting
bool debugRawShareDirIsActive(String path) =>
    _activeRawShareDirs.contains(path);

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

  /// 붙은 줄 번호 범위를 읽는 목록 키(검색 이동 이분 탐색의 방향 피드백용).
  final _listKey = GlobalKey();

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

  /// 검색 이동 체인 세대. 다음·이전·검색 변경 때 올려 이전 체인이 멈추게 한다.
  int _revealGen = 0;

  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _current = (_current + delta) % _matches.length;
      if (_current < 0) _current += _matches.length;
    });
    _revealGen++;
    _revealCycle(
      gen: _revealGen,
      loPx: 0,
      hiPx: null,
      pendingMid: null,
      prevMax: null,
      backtrackPx: null,
      attempt: 0,
    );
  }

  /// 지금 붙어 있는(지연 생성 목록이 만든) 줄 번호 범위. 화면 근처만 붙으므로
  /// 대상 줄이 이 범위보다 위인지 아래인지 방향만 정한다(이분 탐색 피드백).
  /// 목록이 아직 안 붙었으면 null.
  (int, int)? _builtLineRange() {
    final ctx = _listKey.currentContext;
    if (ctx == null) return null;
    int? lo;
    int? hi;
    void visit(Element e) {
      final key = e.widget.key;
      if (key is ValueKey<int>) {
        lo = lo == null || key.value < lo! ? key.value : lo;
        hi = hi == null || key.value > hi! ? key.value : hi;
      }
      e.visitChildren(visit);
    }
    (ctx as Element).visitChildren(visit);
    if (lo == null || hi == null) return null;
    return (lo!, hi!);
  }

  /// 현재 일치를 화면에 보이게 한다. 수천 줄 JSON 에서는 대상 줄이 지연 생성
  /// 목록 밖에 있어 키가 없을 수 있다 — 그때는 화소 구간 이분 탐색으로 좁힌다.
  /// 줄마다 실제 높이가 크게 달라도(앞쪽 매우 긴 줄 등) 화소→줄 대응은 단조라
  /// 붙은 줄 범위로 정한 방향이 정확하고, 구간이 화면보다 작아지면 반드시 닿는다.
  /// 처음 한 번은 대상 줄 번호 비율로 씨앗을 잡고 이후는 순수 이분 탐색이라
  /// 평균 높이 반복처럼 같은 위치에 머물지 않는다. 최대 [maxRawRevealAttempts]번.
  ///
  /// 한 사이클은 프레임 하나다: 이전 점프가 이 프레임에 배치됐으므로 지금 붙은
  /// 줄 범위는 새것이다. 관찰→구간 좁히기→다음 점프→다음 프레임 예약을 한 번에
  /// 한다(관찰과 점프를 같은 post-frame 에 두면 점프 전 범위를 본다).
  void _revealCycle({
    required int gen,
    required double loPx,
    required double? hiPx,
    required double? pendingMid,
    required double? prevMax,
    required double? backtrackPx,
    required int attempt,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (gen != _revealGen ||
          !mounted ||
          _matches.isEmpty ||
          !_scrollController.hasClients) {
        return;
      }
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
      if (attempt >= maxRawRevealAttempts) return;
      final pos = _scrollController.position;
      final curMax = pos.maxScrollExtent;
      var hi = (hiPx ?? curMax).clamp(0.0, curMax).toDouble();
      var lo = loPx.clamp(0.0, hi).toDouble();
      final targetLine = _matches[_current].line;
      // 전체 높이가 한 번에 몇 배로 뛰면 지연 목록의 어림이 깨진 것으로 보고
      // 구간에 들이지 않는다(실제로 긴 줄 하나가 처음 배치되면 수백 배까지 뛴다).
      // 그 외의 증가(긴 줄 배치로 끝이 늘어남)는 상한에 따라간다.
      final grew =
          prevMax != null && curMax > prevMax + 1.0 && prevMax > 0;
      final garbageSpike =
          grew && curMax > prevMax * _maxSaneGrowthRatio;
      if (grew && !garbageSpike && curMax > hi) {
        hi = curMax;
      }
      double? nextBacktrack = backtrackPx;
      var backtrackJump = false;
      // 직전 점프 결과를 지금 붙은 범위로만 좁힌다(첫 사이클은 점프 전이라 건너뜀).
      final mid = pendingMid;
      if (attempt > 0 && mid != null) {
        final range = _builtLineRange();
        if (range != null) {
          if (targetLine < range.$1) {
            hi = mid.clamp(0.0, hi).toDouble();
          } else if (targetLine > range.$2) {
            if (pos.pixels >= curMax - 1.0 && lo > 0) {
              // 끝에 닿았는데 대상이 붙은 범위 아래다: 끝 어림이 낡았고(중간에
              // 안 읽은 긴 줄) 위로는 더 못 간다. 구간을 좁히지 않고 중간을
              // 밟아 배치를 늘린다 — 매번 절반씩 아래로(같은 곳 반복 금지).
              nextBacktrack = (backtrackPx ?? lo) / 2;
              backtrackJump = true;
            } else {
              lo = mid.clamp(lo, hi).toDouble();
            }
          }
          // 범위 안에 있는데 키가 없으면(붙는 중) 구간을 유지하고 다시 본다.
        }
      }
      final double next;
      if (backtrackJump) {
        next = nextBacktrack!;
      } else if (attempt == 0) {
        final total = _data?.pretty.split('\n').length ?? 0;
        next = total > 1
            ? (curMax * targetLine / (total - 1))
                  .clamp(0.0, curMax)
                  .toDouble()
            : 0.0;
      } else {
        next = (lo + hi) / 2;
      }
      _scrollController.jumpTo(next.clamp(0.0, curMax).toDouble());
      // 점프값이 같아 프레임이 안 잡혀도 다음 사이클이 돌게 예약한다(시도 상한이라 끝난다).
      WidgetsBinding.instance.scheduleFrame();
      _revealCycle(
        gen: gen,
        loPx: lo,
        hiPx: hi,
        pendingMid: next,
        prevMax: curMax,
        backtrackPx: nextBacktrack,
        attempt: attempt + 1,
      );
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
            key: _listKey,
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final lineMatches = byLine[i];
              final isCurrentLine =
                  _current >= 0 && _matches[_current].line == i;
              return Row(
                key: ValueKey(i),
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