import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../models/report.dart';
import '../providers/report_provider.dart';
import '../screens/report_list_screen.dart';
import '../services/standalone_auth_service.dart';

const _officialSafetyReportUrl = 'https://www.safetyreport.go.kr/';

void showReportDetailSheet(BuildContext context, Report report) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ReportDetailSheet(report: report),
  );
}

class ReportDetailSheet extends StatelessWidget {
  final Report report;
  const ReportDetailSheet({super.key, required this.report});

  String _ratingLabel() {
    final rating = report.rating;
    if (rating == null || rating <= 0) return '';
    return '★ $rating점';
  }

  Color _statusColor(String s) {
    if (s == '일부수용') return const Color(0xFF43A047);
    if (s.contains('수용') && !s.contains('불')) return Colors.green;
    if (s.contains('불수용')) return Colors.red;
    if (s.contains('처리') || s.contains('진행')) return Colors.orange;
    return Colors.grey;
  }

  /// 처리내용에서 전화번호 추출
  /// ☎/☏/📞 아이콘, 전화/Tel/TEL 키워드, 또는 한국 전화번호 형식 자체 감지
  String? _extractPhone(String text) {
    // 1순위: 전화 아이콘/키워드 뒤 번호
    final iconMatch = RegExp(
      r'(?:[☎☏📞]|전화\s*번호\s*[:：]?|[Tt][Ee][Ll]\s*[:：]?)\s*([0-9][0-9\-\s]{6,14}[0-9])',
    ).firstMatch(text);
    if (iconMatch != null) {
      return iconMatch.group(1)!.replaceAll(RegExp(r'[\s]'), '');
    }
    // 2순위: 한국 전화번호 형식 자체 (02-, 03x-, 04x-, 05x-, 07x-, 010-, 011-, 016-, 017-, 018-, 019-)
    final numMatch = RegExp(
      r'\b(0(?:2|[3-9]\d)[\-\s]\d{3,4}[\-\s]\d{4}|01[016789][\-\s]\d{3,4}[\-\s]\d{4})\b',
    ).firstMatch(text);
    if (numMatch != null) {
      return numMatch.group(1)!.replaceAll(RegExp(r'[\s]'), '');
    }
    return null;
  }

  Future<void> _openInSafetyApp(BuildContext context) async {
    if (report.id.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('신고 ID 정보가 없습니다.')));
      return;
    }
    final uri = Uri.parse(
      'appsafetyreport://view?c_no=${report.id}&ext_path=M_MY_01_S0002.html&mem_yn=Y',
    );
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('안전신문고 앱이 설치되어 있지 않습니다.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('안전신문고 앱이 설치되어 있지 않습니다.')));
      }
    }
  }

  Future<void> _openOfficialSource(BuildContext context) async {
    final uri = Uri.parse(_officialSafetyReportUrl);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('공식 사이트를 열 수 없습니다.')));
    }
  }

  List<String> _splitUrls(String raw) {
    if (raw.isEmpty || raw == '6개월 초과') return [];
    return raw
        .split(RegExp(r'\n|%0A|%0a'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  bool _isVideo(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.mp4') ||
        path.endsWith('.mov') ||
        path.endsWith('.avi') ||
        path.endsWith('.webm') ||
        path.endsWith('.mkv');
  }

  bool _isImage(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png') ||
        path.endsWith('.gif') ||
        path.endsWith('.webp');
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(report.status);
    final photos = _splitUrls(report.attachedPhotos);
    final files = _splitUrls(report.attachedFiles);
    final mapUrls = _splitUrls(report.mapImage);

    // 지도 이미지 → imageUrls 맨 앞에 추가
    final imageUrls = <String>[];
    for (final u in mapUrls) {
      if (!imageUrls.contains(u)) imageUrls.add(u);
    }
    // 첨부사진: 확장자와 무관하게 모두 이미지로 취급 (사진 컬럼이므로)
    // 단, 동영상 확장자가 명확한 경우엔 videoUrls로 분류
    final videoUrls = <String>[];
    for (final u in photos) {
      if (_isVideo(u)) {
        if (!videoUrls.contains(u)) videoUrls.add(u);
      } else {
        if (!imageUrls.contains(u)) imageUrls.add(u);
      }
    }
    // 파일 중 이미지/동영상/기타 분류
    for (final u in files) {
      if (_isImage(u) && !imageUrls.contains(u))
        imageUrls.add(u);
      else if (_isVideo(u) && !videoUrls.contains(u))
        videoUrls.add(u);
    }
    final otherFiles = files
        .where((u) => !_isImage(u) && !_isVideo(u))
        .toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      minChildSize: 0.3,
      builder: (_, sc) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: ListView(
          controller: sc,
          children: [
            // 핸들
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 신고명 + 상태칩
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    report.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (report.status.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: color.withOpacity(0.4)),
                    ),
                    child: Text(
                      report.status,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const Divider(height: 24),
            // 상세 필드
            if (report.reportNumber.isNotEmpty)
              _field(Icons.tag, '신고번호', report.reportNumber),
            if (report.id.isNotEmpty)
              _field(Icons.fingerprint, '내부 ID', report.id),
            if (report.date.isNotEmpty)
              _field(Icons.calendar_today, '신고일', report.date),
            if (report.responseDate.isNotEmpty)
              _field(Icons.check_circle_outline, '답변일', report.responseDate),
            if (report.agency.isNotEmpty)
              _field(Icons.business, '처리기관', report.agency),
            if (report.manager.isNotEmpty)
              _linkField(
                context,
                Icons.person_outline,
                '담당자',
                report.manager,
                ReportFilter(manager: report.manager),
              ),
            if (report.fineInfo.isNotEmpty)
              _field(
                Icons.monetization_on_outlined,
                '과태료/범칙금',
                report.fineInfo,
              ),
            if (report.penaltyPoints.isNotEmpty)
              _field(Icons.warning_amber_outlined, '벌점', report.penaltyPoints),
            if (report.carNumber.isNotEmpty)
              _linkField(
                context,
                Icons.directions_car,
                '차량번호',
                report.carNumber,
                ReportFilter(carNumber: report.carNumber),
              ),
            if (report.law.isNotEmpty)
              _linkField(
                context,
                Icons.gavel_outlined,
                '위반법규',
                report.law,
                ReportFilter(law: report.law),
              ),
            if (report.location.isNotEmpty)
              _linkField(
                context,
                Icons.location_on_outlined,
                '위반장소',
                report.location,
                ReportFilter(location: report.location),
              ),
            if (report.occurrenceDate.isNotEmpty)
              _field(
                Icons.event_outlined,
                '발생일자',
                report.occurrenceDate +
                    (report.occurrenceTime.isNotEmpty
                        ? '  ${report.occurrenceTime}'
                        : ''),
              ),
            if (_ratingLabel().isNotEmpty)
              _field(Icons.star_outline, '별점', _ratingLabel()),
            if (report.ratingCause.isNotEmpty)
              _field(Icons.comment_outlined, '별점사유', report.ratingCause),
            if (report.reportContent.isNotEmpty) ...[
              const Divider(height: 20),
              _textBlock('신고내용', report.reportContent),
            ],
            if (report.supplementCount > 0 ||
                report.supplementRequester.isNotEmpty ||
                report.supplementRequestedAt.isNotEmpty ||
                report.supplementCompletedAt.isNotEmpty ||
                report.supplementRequest.isNotEmpty ||
                report.supplementOpinion.isNotEmpty) ...[
              const SizedBox(height: 12),
              _SupplementSection(report: report),
            ],
            if (report.processContent.isNotEmpty) ...[
              const SizedBox(height: 8),
              _textBlock('처리내용', report.processContent),
              Builder(
                builder: (ctx) {
                  final phone = _extractPhone(report.processContent);
                  if (phone == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.phone, size: 16),
                      label: Text('전화걸기  $phone'),
                      onPressed: () async {
                        final uri = Uri.parse('tel:$phone');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri);
                        }
                      },
                    ),
                  );
                },
              ),
            ],
            // 인라인 이미지
            if (imageUrls.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionLabel('첨부 사진'),
              const SizedBox(height: 8),
              ...imageUrls.map(
                (url) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _RetryableImage(url: url),
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text(
                          '다른 앱으로 열기',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                        ),
                        onPressed: () => _openExternal(context, url),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            // 인라인 동영상
            if (videoUrls.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionLabel('첨부 동영상'),
              const SizedBox(height: 8),
              ...videoUrls.map(
                (url) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _VideoPlayer(url: url),
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text(
                          '다른 앱으로 열기',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                        ),
                        onPressed: () => _openExternal(context, url),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            // 기타 첨부파일 — 인라인 동영상 재생 시도
            if (otherFiles.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionLabel('첨부파일'),
              const SizedBox(height: 4),
              ...otherFiles.asMap().entries.map((e) {
                final url = e.value;
                final idx = e.key + 1;
                final fileName =
                    Uri.tryParse(
                      url,
                    )?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ??
                    '첨부파일 $idx';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _VideoPlayer(url: url, label: fileName),
                );
              }),
            ],
            const SizedBox(height: 20),
            // 안전신문고 앱으로 이동
            FilledButton.icon(
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('안전신문고 앱에서 보기'),
              onPressed: () => _openInSafetyApp(context),
            ),
            const SizedBox(height: 4),
            Text(
              '안전신문고 앱이 설치되어 있고 로그인된 상태여야 합니다.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blueGrey.shade100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '정부 정보 원문 출처',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const SelectableText(
                    _officialSafetyReportUrl,
                    style: TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_browser, size: 16),
                      label: const Text('안전신문고 공식 사이트 열기'),
                      onPressed: () => _openOfficialSource(context),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '이 앱은 안전신문고의 공식 앱이 아니며 행정안전부 또는 정부기관을 대표하지 않습니다.',
                    style: TextStyle(fontSize: 12.5, height: 1.45),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '안전신문고 데이터를 사용자의 편의를 위해 조회·정리해 보여주는 비공식 도구입니다.',
                    style: TextStyle(fontSize: 12.5, height: 1.45),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '원문 확인과 실제 민원 처리는 안전신문고 공식 서비스에서 진행해 주세요.',
                    style: TextStyle(fontSize: 12.5, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 파일을 캐시에 다운로드한 뒤 Android ACTION_VIEW로 다른 앱에 전달
  Future<void> _openExternal(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    // 파일명 추출 (쿼리스트링 제거)
    final fileName = uri.pathSegments.lastWhere(
      (s) => s.isNotEmpty,
      orElse: () => 'file_${DateTime.now().millisecondsSinceEpoch}',
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('파일 불러오는 중...'),
        duration: Duration(seconds: 10),
      ),
    );

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');

      // 이미 캐시에 있으면 재사용
      if (!await file.exists()) {
        final response = await http.get(uri);
        await file.writeAsBytes(response.bodyBytes);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }

      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('열 수 있는 앱이 없습니다: ${result.message}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('파일을 열지 못했습니다: $e')));
      }
    }
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.bold,
      color: Colors.grey.shade700,
    ),
  );

  Widget _textBlock(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: SelectableText(
            value,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
      ],
    );
  }

  Widget _field(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  /// 신고 카테고리(traffic/parking/other)에 맞는 신고리스트 탭으로
  /// 특정 필드 값을 검색 조건으로 넘겨 이동.
  Widget _linkField(
    BuildContext context,
    IconData icon,
    String label,
    String value,
    ReportFilter filter,
  ) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _navigateToFiltered(context, filter),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 8),
              SizedBox(
                width: 82,
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: color,
                    decoration: TextDecoration.underline,
                    decorationColor: color.withOpacity(0.5),
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 16,
                color: color.withOpacity(0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _navigateToFiltered(
    BuildContext context,
    ReportFilter filter,
  ) async {
    final navigator = Navigator.of(context);
    final provider = context.read<ReportProvider>();
    var category = provider.findCategory(report);
    if (category == null) {
      await provider.ensureCategoryReportsLoaded();
      if (!context.mounted) return;
      category = provider.findCategory(report);
    }
    if (category == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('신고 카테고리 정보를 찾지 못했습니다.')));
      return;
    }

    final tabIndex = provider.categoryToTabIndex(category);
    provider.setFilter(filter);
    navigator.pop(); // close bottom sheet
    navigator.push(
      MaterialPageRoute(
        builder: (_) => ReportListScreen(initialTabIndex: tabIndex),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
class _FullscreenVideoPage extends StatefulWidget {
  final VideoPlayerController controller;
  const _FullscreenVideoPage({required this.controller});

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  bool _seeking = false;
  bool _wasPlaying = false;
  Duration _seekPosition = Duration.zero;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.controller.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _onVideoTap() {
    if (!_showControls) {
      setState(() => _showControls = true);
      if (widget.controller.value.isPlaying) _scheduleHide();
    } else {
      if (widget.controller.value.isPlaying) {
        widget.controller.pause();
        _hideTimer?.cancel();
        setState(() => _showControls = true);
      } else {
        widget.controller.play();
        _scheduleHide();
        setState(() {});
      }
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 영상 — GestureDetector는 탭으로 컨트롤 토글/재생
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onVideoTap,
              child: Center(
                child: AspectRatio(
                  aspectRatio: widget.controller.value.aspectRatio,
                  child: VideoPlayer(widget.controller),
                ),
              ),
            ),
          ),
          // 하단 컨트롤 바 — 재생 중 자동 숨김
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: widget.controller,
                  builder: (_, value, __) {
                    final pos = _seeking ? _seekPosition : value.position;
                    final dur = value.duration;
                    final maxMs = dur.inMilliseconds > 0
                        ? dur.inMilliseconds.toDouble()
                        : 1.0;
                    final posMs = pos.inMilliseconds.toDouble().clamp(
                      0.0,
                      maxMs,
                    );
                    return Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.only(
                        left: 4,
                        right: 4,
                        bottom: 2,
                      ),
                      child: Row(
                        children: [
                          // 재생/일시정지
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            icon: Icon(
                              value.isPlaying ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                              size: 22,
                            ),
                            onPressed: () {
                              if (value.isPlaying) {
                                widget.controller.pause();
                                _hideTimer?.cancel();
                                setState(() => _showControls = true);
                              } else {
                                widget.controller.play();
                                _scheduleHide();
                                setState(() {});
                              }
                            },
                          ),
                          Text(
                            _fmt(pos),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                                trackHeight: 2,
                                activeTrackColor: Colors.white,
                                inactiveTrackColor: Colors.white30,
                                thumbColor: Colors.white,
                                overlayColor: Colors.white24,
                              ),
                              child: Slider(
                                value: posMs,
                                min: 0,
                                max: maxMs,
                                onChangeStart: (_) {
                                  _wasPlaying = value.isPlaying;
                                  if (_wasPlaying) widget.controller.pause();
                                  setState(() {
                                    _seeking = true;
                                    _seekPosition = pos;
                                  });
                                },
                                onChanged: (v) => setState(
                                  () => _seekPosition = Duration(
                                    milliseconds: v.toInt(),
                                  ),
                                ),
                                onChangeEnd: (v) {
                                  widget.controller.seekTo(
                                    Duration(milliseconds: v.toInt()),
                                  );
                                  if (_wasPlaying) widget.controller.play();
                                  setState(() => _seeking = false);
                                },
                              ),
                            ),
                          ),
                          Text(
                            _fmt(dur),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                          // 축소 버튼 (우측)
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            icon: const Icon(
                              Icons.fullscreen_exit,
                              color: Colors.white,
                              size: 22,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
/// 로드 실패 시 2초 후 자동 1회 재시도하는 이미지 위젯
class _RetryableImage extends StatefulWidget {
  final String url;
  const _RetryableImage({required this.url});

  @override
  State<_RetryableImage> createState() => _RetryableImageState();
}

class _RetryableImageState extends State<_RetryableImage> {
  static const _maxAutoRetry = 5;
  static const _retryDelay = Duration(seconds: 1);

  int _attempt = 0;
  bool _failed = false; // 최종 실패 (수동 버튼 표시)
  bool _retrying = false; // 재시도 대기 중 (스피너 표시)
  Timer? _retryTimer;
  Map<String, String>? _headers;

  @override
  void initState() {
    super.initState();
    // 안전신문고 직접 URL은 Bearer 토큰이 필요
    if (widget.url.contains('safetyreport.go.kr')) {
      StandaloneAuthService.getStoredToken().then((token) {
        if (token != null && mounted) {
          setState(() => _headers = {'Authorization': 'BEARER $token'});
        }
      });
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _onError() {
    if (!mounted) return;
    if (_attempt < _maxAutoRetry) {
      setState(() => _retrying = true);
      _retryTimer = Timer(_retryDelay, () {
        if (!mounted) return;
        setState(() {
          _attempt++;
          _retrying = false;
        });
      });
    } else {
      setState(() {
        _failed = true;
        _retrying = false;
      });
    }
  }

  void _manualRetry() {
    if (!mounted) return;
    setState(() {
      _attempt++;
      _failed = false;
      _retrying = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Container(
        height: 80,
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, color: Colors.grey),
              TextButton(
                onPressed: _manualRetry,
                child: const Text('다시 시도', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        widget.url,
        key: ValueKey('${widget.url}_$_attempt'),
        headers: _headers,
        fit: BoxFit.cover,
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child; // 로드 완료
          if (_retrying) {
            return Container(
              height: 160,
              color: Colors.grey.shade100,
              child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return Container(
            height: 160,
            color: Colors.grey.shade100,
            child: Center(
              child: CircularProgressIndicator(
                value: progress.expectedTotalBytes != null
                    ? progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!
                    : null,
              ),
            ),
          );
        },
        errorBuilder: (_, __, ___) {
          // errorBuilder는 동기적으로 호출되므로 addPostFrameCallback으로 상태 변경
          WidgetsBinding.instance.addPostFrameCallback((_) => _onError());
          return Container(
            height: 80,
            color: Colors.grey.shade100,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        },
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
class _VideoPlayer extends StatefulWidget {
  final String url;
  final String? label; // 파일명 표시용 (otherFiles에서 사용)
  const _VideoPlayer({required this.url, this.label});

  @override
  State<_VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<_VideoPlayer> {
  late VideoPlayerController _ctrl;
  bool _initialized = false;
  bool _error = false;
  bool _seeking = false;
  bool _wasPlaying = false;
  Duration _seekPosition = Duration.zero;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  void _initController() {
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize()
          .then((_) {
            if (mounted) setState(() => _initialized = true);
          })
          .catchError((_) {
            if (mounted) setState(() => _error = true);
          });
  }

  // 재생 시작 시 3초 후 컨트롤 자동 숨김
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _ctrl.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  // 컨트롤 표시 + 타이머 재시작
  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    if (_ctrl.value.isPlaying) _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.label ?? '동영상',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () {
                if (mounted)
                  setState(() {
                    _error = false;
                    _initialized = false;
                    _seeking = false;
                    _seekPosition = Duration.zero;
                  });
                _ctrl.dispose();
                _initController();
              },
              child: const Text('재시도', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }
    if (!_initialized) {
      return Container(
        height: 160,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          AspectRatio(
            aspectRatio: _ctrl.value.aspectRatio,
            child: GestureDetector(
              onTap: () {
                if (!_showControls) {
                  _showControlsTemporarily();
                } else if (_ctrl.value.isPlaying) {
                  _ctrl.pause();
                  _hideTimer?.cancel();
                  setState(() => _showControls = true);
                } else {
                  _ctrl.play();
                  _scheduleHide();
                  setState(() {});
                }
              },
              child: VideoPlayer(_ctrl),
            ),
          ),
          // 하단 컨트롤 바
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _ctrl,
            builder: (_, value, __) {
              final pos = _seeking ? _seekPosition : value.position;
              final dur = value.duration;
              final maxMs = dur.inMilliseconds > 0
                  ? dur.inMilliseconds.toDouble()
                  : 1.0;
              final posMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
              return AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.only(
                      left: 4,
                      right: 8,
                      bottom: 2,
                    ),
                    child: Row(
                      children: [
                        // 재생/일시정지 버튼
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          icon: Icon(
                            value.isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 22,
                          ),
                          onPressed: () {
                            if (value.isPlaying) {
                              _ctrl.pause();
                              _hideTimer?.cancel();
                              setState(() => _showControls = true);
                            } else {
                              _ctrl.play();
                              _scheduleHide();
                              setState(() {});
                            }
                          },
                        ),
                        // 현재 위치
                        Text(
                          _fmt(pos),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                        // 시크 바
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                              trackHeight: 2,
                              activeTrackColor: Colors.white,
                              inactiveTrackColor: Colors.white30,
                              thumbColor: Colors.white,
                              overlayColor: Colors.white24,
                            ),
                            child: Slider(
                              value: posMs,
                              min: 0,
                              max: maxMs,
                              onChangeStart: (_) {
                                _wasPlaying = value.isPlaying;
                                if (_wasPlaying) _ctrl.pause();
                                setState(() {
                                  _seeking = true;
                                  _seekPosition = pos;
                                });
                              },
                              onChanged: (v) => setState(
                                () => _seekPosition = Duration(
                                  milliseconds: v.toInt(),
                                ),
                              ),
                              onChangeEnd: (v) {
                                _ctrl.seekTo(Duration(milliseconds: v.toInt()));
                                if (_wasPlaying) _ctrl.play();
                                setState(() => _seeking = false);
                              },
                            ),
                          ),
                        ),
                        // 전체 길이
                        Text(
                          _fmt(dur),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        // 전체화면
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                          icon: const Icon(
                            Icons.fullscreen,
                            color: Colors.white,
                            size: 22,
                          ),
                          onPressed: _openFullscreen,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _openFullscreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenVideoPage(controller: _ctrl),
      ),
    );
  }
}

/// 보완요청 마지막 round 카드. 다회차 이력 전체는 별도 API 없이 신고 row 컬럼만 사용.
class _SupplementSection extends StatelessWidget {
  final Report report;
  const _SupplementSection({required this.report});

  @override
  Widget build(BuildContext context) {
    final count = report.supplementCount;
    final open = report.supplementOpen;
    final requester = report.supplementRequester.trim();
    final requestedAt = report.supplementRequestedAt.trim();
    final completedAt = report.supplementCompletedAt.trim();
    final request = report.supplementRequest.trim();
    final opinion = report.supplementOpinion.trim();
    final accent = open ? const Color(0xFFFD7E14) : Colors.grey.shade600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.history_edu, size: 16, color: Color(0xFFFD7E14)),
            const SizedBox(width: 6),
            const Text(
              '보완 요청',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Color(0xFFFD7E14),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFD7E14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '$count회',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: open ? Colors.red : Colors.grey,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                open ? '미응답' : '응답 완료',
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: open
                ? const Color(0xFFFD7E14).withValues(alpha: 0.08)
                : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: accent.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (requester.isNotEmpty ||
                  requestedAt.isNotEmpty ||
                  completedAt.isNotEmpty) ...[
                if (requester.isNotEmpty)
                  _SupplementMetaRow(label: '보완 요청자', value: requester),
                if (requestedAt.isNotEmpty)
                  _SupplementMetaRow(label: '요청 일시', value: requestedAt),
                _SupplementMetaRow(
                  label: '완료 일시',
                  value: completedAt.isNotEmpty ? completedAt : '(미응답)',
                ),
                const SizedBox(height: 8),
              ],
              Text(
                request.isNotEmpty ? request : '(요청 내용 없음)',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
              if (opinion.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text(
                  '신고자 의견',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  opinion,
                  style: const TextStyle(fontSize: 12.5, height: 1.5),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SupplementMetaRow extends StatelessWidget {
  final String label;
  final String value;

  const _SupplementMetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 12, height: 1.45),
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(color: Colors.black87),
            ),
          ],
        ),
      ),
    );
  }
}
