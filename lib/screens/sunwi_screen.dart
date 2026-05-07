import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../models/sunwi.dart';
import '../providers/report_provider.dart';
import '../services/repositories/sunwi_repository.dart';

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
            const Icon(Icons.map_outlined, size: 18, color: Colors.indigo),
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
              icon: const Icon(Icons.refresh),
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
              style: const TextStyle(fontSize: 13, height: 1.5),
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
              color: Colors.grey.shade500,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: _error == null ? Colors.black87 : Colors.red.shade700,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _load(force: true),
              icon: const Icon(Icons.refresh),
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
                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
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
              Icon(Icons.map_outlined, size: 54, color: Colors.grey.shade500),
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
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            Text(
              child.fullName,
              style: const TextStyle(fontSize: 13, color: Colors.black54),
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
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left),
            tooltip: '이전',
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.black54,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
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
        color: const Color(0xFFF8F9FB),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Text(
        '이번 기간 데이터가 없습니다.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.black54),
      ),
    );
  }

  Widget _buildRankItem(SunwiItem item) {
    final colors = [
      const Color(0xFF1A73E8),
      const Color(0xFF198754),
      const Color(0xFFFD7E14),
      const Color(0xFF6F42C1),
      const Color(0xFFDC3545),
    ];
    final badgeColor =
        colors[(item.rank - 1).clamp(0, colors.length - 1).toInt()];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE6EAF0)),
        gradient: const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFFF7FAFF)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '${item.rank}위',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.region,
              style: const TextStyle(fontWeight: FontWeight.bold, height: 1.35),
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
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: Colors.black54),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 1.25),
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
