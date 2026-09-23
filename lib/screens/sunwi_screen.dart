import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../models/sunwi.dart';
import '../providers/report_provider.dart';
import '../services/repositories/sunwi_repository.dart';
import '../theme/sr_colors.dart';
import '../server_palette.dart';

class SunwiScreen extends StatelessWidget {
  const SunwiScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('신고현황')),
      body: const SunwiSection(),
    );
  }
}

class SunwiSection extends StatefulWidget {
  final bool embedded;

  const SunwiSection({super.key, this.embedded = false});

  @override
  State<SunwiSection> createState() => _SunwiSectionState();
}

class _SunwiSectionState extends State<SunwiSection> {
  static const _resyncInterval = Duration(hours: 3);
  static const _autoPageInterval = Duration(seconds: 5);
  static final Map<AppMode, _SunwiCacheEntry> _cacheByMode = {};

  SunwiPayload? _payload;
  bool _loading = true;
  String? _error;
  String _statusMessage = '';
  int _parentIndex = 0;
  int _childIndex = 0;
  int _lastRefreshNonce = 0;
  bool _requestInFlight = false;
  Timer? _autoPageTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _autoPageTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nonce = context.watch<ReportProvider>().sunwiRefreshNonce;
    if (nonce != _lastRefreshNonce) {
      _lastRefreshNonce = nonce;
      if (nonce != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
      }
    }
  }

  Future<void> _load({bool force = false}) async {
    if (_requestInFlight) return;
    final provider = context.read<ReportProvider>();
    final appMode = provider.appMode;
    final cached = _freshCacheFor(appMode, force: force);
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _payload = cached.payload;
        _loading = false;
        _error = null;
        _statusMessage = '';
      });
      _syncSelection();
      _resetAutoPageTimer();
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _statusMessage = '';
      });
    }

    _requestInFlight = true;
    try {
      final repo = SunwiRepository.fromProvider(provider);
      final snapshot = await repo.fetch(
        onProgress: (completed, total, label) {
          if (!mounted) return;
          setState(() {
            _statusMessage = '전국 신고현황 수집 중... ($completed/$total) $label';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _payload = snapshot.payload;
        _statusMessage = '';
      });
      _cacheByMode[appMode] = _SunwiCacheEntry(
        snapshot: snapshot,
        fetchedAt: DateTime.now(),
      );
      _syncSelection();
      _resetAutoPageTimer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        if (_payload != null) {
          _statusMessage = '새 동기화에 실패해 기존 데이터를 유지합니다.';
        }
      });
    } finally {
      _requestInFlight = false;
      if (mounted) {
        setState(() {
          _loading = false;
          if (_statusMessage.isEmpty && _payload != null) {
            _statusMessage = '';
          }
        });
      }
      _resetAutoPageTimer();
    }
  }

  _SunwiCacheEntry? _freshCacheFor(AppMode mode, {required bool force}) {
    if (force) return null;
    final cached = _cacheByMode[mode];
    if (cached == null) return null;
    if (DateTime.now().difference(cached.fetchedAt) >= _resyncInterval) {
      return null;
    }
    return cached;
  }

  void _syncSelection() {
    final payload = _payload;
    if (payload == null || payload.categories.isEmpty) {
      _parentIndex = 0;
      _childIndex = 0;
      return;
    }
    if (_parentIndex >= payload.categories.length) {
      _parentIndex = payload.categories.length - 1;
    }
    final children = payload.categories[_parentIndex].children;
    if (children.isEmpty) {
      _childIndex = 0;
      return;
    }
    if (_childIndex >= children.length) {
      _childIndex = children.length - 1;
    }
  }

  SunwiParentCategory? get _currentParent {
    final payload = _payload;
    if (payload == null || payload.categories.isEmpty) return null;
    return payload.categories[_parentIndex];
  }

  SunwiChildCategory? get _currentChild {
    final parent = _currentParent;
    if (parent == null || parent.children.isEmpty) return null;
    return parent.children[_childIndex];
  }

  void _moveParent(int delta) {
    final payload = _payload;
    if (payload == null || payload.categories.isEmpty) return;
    setState(() {
      _parentIndex = (_parentIndex + delta)
          .clamp(0, payload.categories.length - 1)
          .toInt();
      _childIndex = 0;
    });
    _resetAutoPageTimer();
  }

  void _moveChild(int delta) {
    final parent = _currentParent;
    if (parent == null || parent.children.isEmpty) return;
    setState(() {
      _childIndex = (_childIndex + delta)
          .clamp(0, parent.children.length - 1)
          .toInt();
    });
    _resetAutoPageTimer();
  }

  void _resetAutoPageTimer() {
    _autoPageTimer?.cancel();
    if (!_shouldAutoPage) return;
    _autoPageTimer = Timer.periodic(_autoPageInterval, (_) {
      if (!mounted) return;
      _advancePage();
    });
  }

  bool get _shouldAutoPage {
    final payload = _payload;
    if (payload == null || !payload.available || payload.categories.isEmpty) {
      return false;
    }
    if (payload.categories.length > 1) return true;
    return payload.categories.first.children.length > 1;
  }

  void _advancePage() {
    final payload = _payload;
    if (payload == null || !payload.available || payload.categories.isEmpty) {
      return;
    }

    final parentCount = payload.categories.length;
    final parent = payload.categories[_parentIndex];
    final childCount = parent.children.length;

    if (childCount > 1) {
      setState(() {
        final nextChild = (_childIndex + 1) % childCount;
        if (nextChild == 0 && parentCount > 1) {
          _parentIndex = (_parentIndex + 1) % parentCount;
          _childIndex = 0;
        } else {
          _childIndex = nextChild;
        }
      });
      return;
    }

    if (parentCount > 1) {
      setState(() {
        _parentIndex = (_parentIndex + 1) % parentCount;
        _childIndex = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ReportProvider>();
    final children = _buildChildren();

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: children,
      ),
    );
  }

  List<Widget> _buildChildren() {
    return [
      if (widget.embedded)
        Row(
          children: [
            Icon(
              Icons.map_outlined,
              size: 18,
              color: StatusTone.of(
                changeDuplicateColor,
                brightness: Theme.of(context).brightness,
                surface: context.sr.surface,
              ).foreground,
            ),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                '신고현황',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              onPressed: _loading ? null : () => _load(force: true),
              tooltip: '새로고침',
              icon: Icon(Icons.refresh),
            ),
          ],
        ),
      if (widget.embedded) const SizedBox(height: 8),
      if (_loading && _payload == null) _buildLoadingState(),
      if (!_loading && _payload == null) _buildEmptyOrErrorState(),
      if (_payload != null) ...[
        _buildInfoCard(),
        const SizedBox(height: 12),
        if (_loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        _buildCategoryCard(),
      ],
    ];
  }

  Widget _buildLoadingState() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _statusMessage.isEmpty ? '신고현황을 불러오는 중입니다.' : _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyOrErrorState() {
    final message = _error ?? '표시할 신고현황 데이터가 없습니다.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          children: [
            Icon(
              _error == null ? Icons.inbox_outlined : Icons.error_outline,
              size: 54,
              color: context.sr.textDisabled,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: _error == null
                    ? context.sr.textPrimary
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _load(force: true),
              icon: Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    final payload = _payload!;
    final failedText = payload.failedCount > 0
        ? '일부 지역 실패 ${payload.failedCount}건'
        : '실패 지역 없음';
    final periodLabel = payload.periodLabel.isEmpty
        ? '집계 기간 없음'
        : payload.periodLabel;
    final metaItems = [
      const _MetaChip(icon: Icons.calendar_today_outlined, label: '전일기준'),
      _MetaChip(
        icon: Icons.schedule_outlined,
        label: payload.updatedAt.isEmpty ? '수집 시각 없음' : payload.updatedAt,
      ),
      _MetaChip(
        icon: payload.failedCount > 0
            ? Icons.warning_amber_rounded
            : Icons.check_circle_outline,
        label: failedText,
      ),
      _MetaChip(icon: Icons.date_range_outlined, label: periodLabel),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '전국 안전신문고 통계',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: metaItems[0]),
                const SizedBox(width: 8),
                Expanded(child: metaItems[1]),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: metaItems[2]),
                const SizedBox(width: 8),
                Expanded(child: metaItems[3]),
              ],
            ),
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _statusMessage,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (payload.error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                payload.error,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryCard() {
    final payload = _payload!;
    final parent = _currentParent;
    final child = _currentChild;

    if (!payload.available || parent == null || child == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          child: Column(
            children: [
              Icon(
                Icons.map_outlined,
                size: 54,
                color: context.sr.textDisabled,
              ),
              const SizedBox(height: 12),
              const Text('표시 가능한 신고현황 데이터가 없습니다.', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildNavigator(
              title: '대분류',
              value: parent.name,
              onPrev: _parentIndex > 0 ? () => _moveParent(-1) : null,
              onNext: _parentIndex < payload.categories.length - 1
                  ? () => _moveParent(1)
                  : null,
            ),
            const SizedBox(height: 12),
            _buildNavigator(
              title: '소분류',
              value: child.name,
              onPrev: _childIndex > 0 ? () => _moveChild(-1) : null,
              onNext: _childIndex < parent.children.length - 1
                  ? () => _moveChild(1)
                  : null,
            ),
            const SizedBox(height: 14),
            Text(
              '대분류와 소분류는 5초마다 자동으로 전환됩니다.',
              style: TextStyle(fontSize: 12, color: context.sr.textSecondary),
            ),
            const SizedBox(height: 10),
            Text(
              child.fullName,
              style: TextStyle(fontSize: 13, color: context.sr.textSecondary),
            ),
            const SizedBox(height: 14),
            if (child.items.isEmpty)
              _buildNoItems()
            else
              ...child.items.map(_buildRankItem),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigator({
    required String title,
    required String value,
    required VoidCallback? onPrev,
    required VoidCallback? onNext,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: context.sr.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onPrev,
            icon: Icon(Icons.chevron_left),
            tooltip: '이전',
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    color: context.sr.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: Icon(Icons.chevron_right),
            tooltip: '다음',
          ),
        ],
      ),
    );
  }

  Widget _buildNoItems() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: context.sr.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        '이번 기간 데이터가 없습니다.',
        textAlign: TextAlign.center,
        style: TextStyle(color: context.sr.textSecondary),
      ),
    );
  }

  Widget _buildRankItem(SunwiItem item) {
    // 순위 배지: 기준색 틴트 + AA 글자(흰 글자 채움은 다크에서 대비가 무너진다).
    const rankBases = [
      Color(0xFF0D6EFD),
      serverAcceptColor,
      serverSupplementColor,
      Color(0xFF8B5CF6),
      serverRejectColor,
    ];
    final theme = Theme.of(context);
    final badgeTone = StatusTone.of(
      rankBases[(item.rank - 1).clamp(0, rankBases.length - 1).toInt()],
      brightness: theme.brightness,
      surface: context.sr.surface,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: context.sr.border),
        gradient: LinearGradient(
          colors: [context.sr.surface, context.sr.surfaceAlt],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: badgeTone.background,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: badgeTone.border),
            ),
            child: Text(
              '${item.rank}위',
              style: TextStyle(
                color: badgeTone.foreground,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.region,
              style: TextStyle(fontWeight: FontWeight.bold, height: 1.35),
            ),
          ),
          const SizedBox(width: 12),
          Text.rich(
            TextSpan(
              text: item.count.toString(),
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
              children: const [
                TextSpan(
                  text: '건',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: context.sr.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: context.sr.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}

class _SunwiCacheEntry {
  final SunwiSnapshot snapshot;
  final DateTime fetchedAt;

  const _SunwiCacheEntry({required this.snapshot, required this.fetchedAt});

  SunwiPayload get payload => snapshot.payload;
}
