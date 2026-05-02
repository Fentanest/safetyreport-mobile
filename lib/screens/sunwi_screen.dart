import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/app_mode.dart';
import '../models/sunwi.dart';
import '../providers/report_provider.dart';
import '../services/api_service.dart';
import '../services/sunwi_service.dart';

class SunwiScreen extends StatefulWidget {
  const SunwiScreen({super.key});

  @override
  State<SunwiScreen> createState() => _SunwiScreenState();
}

class _SunwiScreenState extends State<SunwiScreen> {
  SunwiPayload? _payload;
  SunwiDataset? _dataset;
  bool _loading = true;
  bool _exporting = false;
  String? _error;
  String _statusMessage = '';
  int _parentIndex = 0;
  int _childIndex = 0;
  int _lastRefreshNonce = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _statusMessage = '';
      });
    }

    try {
      final provider = context.read<ReportProvider>();
      if (provider.appMode == AppMode.standalone) {
        final dataset = await SunwiService.fetchStandalone(
          onProgress: (completed, total, label) {
            if (!mounted) return;
            setState(() {
              _statusMessage = '전국 신고현황 수집 중... ($completed/$total) $label';
            });
          },
        );
        if (!mounted) return;
        setState(() {
          _dataset = dataset;
          _payload = dataset.payload;
        });
      } else {
        final api = ApiService(
          baseUrl: provider.baseUrl,
          apiKey: provider.apiKey,
        );
        final payload = await api.getSunwiPayload();
        if (!mounted) return;
        setState(() {
          _dataset = null;
          _payload = payload;
        });
      }
      _syncSelection();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          if (_statusMessage.isEmpty && _payload != null) {
            _statusMessage = '';
          }
        });
      }
    }
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

  Future<void> _exportCsv(bool top5) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final provider = context.read<ReportProvider>();
      if (Platform.isAndroid) {
        final status = await Permission.storage.status;
        if (!status.isGranted) {
          await Permission.storage.request();
        }
      }

      if (provider.appMode == AppMode.standalone) {
        var dataset = _dataset;
        if (dataset == null) {
          await _load();
          dataset = _dataset;
        }
        if (dataset == null) {
          throw Exception('신고현황 데이터를 먼저 불러와주세요.');
        }
        final path = await SunwiService.exportStandaloneCsv(
          dataset,
          top5: top5,
        );
        if (!mounted) return;
        _showSnack(
          '${top5 ? 'TOP5' : 'ALL'} CSV 저장 완료\n$path',
          color: Colors.green,
        );
        return;
      }

      final api = ApiService(
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
      );
      final result = await api.exportSunwiCsv(top5 ? 'top5' : 'all');
      if (!mounted) return;
      final path = result['path']?.toString() ?? '';
      _showSnack(
        '서버 ${top5 ? 'TOP5' : 'ALL'} CSV 생성 완료\n$path',
        color: Colors.green,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('CSV 생성 실패: $e', color: Colors.red);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showSnack(String msg, {required Color color}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: const Duration(seconds: 4),
      ),
    );
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
  }

  void _moveChild(int delta) {
    final parent = _currentParent;
    if (parent == null || parent.children.isEmpty) return;
    setState(() {
      _childIndex = (_childIndex + delta)
          .clamp(0, parent.children.length - 1)
          .toInt();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReportProvider>();
    final isStandalone = provider.appMode == AppMode.standalone;
    return Scaffold(
      appBar: AppBar(title: const Text('신고현황')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            _buildActionCard(isStandalone),
            const SizedBox(height: 12),
            if (_loading && _payload == null) _buildLoadingState(),
            if (!_loading && _payload == null) _buildEmptyOrErrorState(),
            if (_payload != null) ...[
              _buildInfoCard(isStandalone),
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
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard(bool isStandalone) {
    final modeLabel = isStandalone ? 'Standalone 직접 수집' : 'Server 캐시 표시';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  avatar: Icon(
                    isStandalone ? Icons.storage_rounded : Icons.cloud_done,
                    size: 18,
                  ),
                  label: Text(modeLabel),
                ),
                FilledButton.icon(
                  onPressed: _exporting ? null : () => _exportCsv(false),
                  icon: _exporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.table_chart_outlined),
                  label: const Text('ALL CSV 생성'),
                ),
                OutlinedButton.icon(
                  onPressed: _exporting ? null : () => _exportCsv(true),
                  icon: const Icon(Icons.leaderboard_outlined),
                  label: const Text('TOP5 CSV 생성'),
                ),
                IconButton(
                  onPressed: _loading ? null : _load,
                  tooltip: '새로고침',
                  icon: const Icon(Icons.refresh),
                ),
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
          ],
        ),
      ),
    );
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
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(bool isStandalone) {
    final payload = _payload!;
    final failedText = payload.failedCount > 0
        ? '일부 지역 실패 ${payload.failedCount}건'
        : '실패 지역 없음';
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MetaChip(
                  icon: Icons.calendar_today_outlined,
                  label: payload.periodLabel.isEmpty
                      ? '기간 미확인'
                      : '${payload.periodLabel} 기준',
                ),
                _MetaChip(
                  icon: Icons.schedule_outlined,
                  label: payload.updatedAt.isEmpty
                      ? '수집 시각 없음'
                      : payload.updatedAt,
                ),
                _MetaChip(
                  icon: payload.failedCount > 0
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle_outline,
                  label: failedText,
                ),
                _MetaChip(
                  icon: isStandalone ? Icons.phone_android : Icons.dns,
                  label: isStandalone ? '기기 직접 조회' : '서버 캐시 사용',
                ),
              ],
            ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.black54),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
