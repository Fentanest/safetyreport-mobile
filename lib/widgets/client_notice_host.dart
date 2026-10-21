import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../community/client_notice.dart';
import '../community/community_store.dart';
import 'community_account_card.dart' show communityAuthNavigatorKey;

/// Shows the applicable [ClientNotice]: `required` as a dialog, `info`/`warning` as a banner.
/// A notice is shown at most once a day (history is persisted by notice hash).
class ClientNoticeHost extends StatefulWidget {
  const ClientNoticeHost({super.key, required this.child, this.store});
  final Widget child;

  /// Test hook; production opens the shared community store lazily.
  final CommunityStore? store;
  @override
  State<ClientNoticeHost> createState() => _ClientNoticeHostState();
}

class _ClientNoticeHostState extends State<ClientNoticeHost> {
  String? _handled;

  /// Identity of the notice being resolved. Set synchronously: the listener and _load() both call
  /// _show() within the same tick, and each would otherwise pass the awaits below and open a dialog.
  String? _resolving;
  bool _bannerHidden = false;
  Map<String, Object?>? _banner;

  @override
  void initState() {
    super.initState();
    ClientNotice.current.addListener(_show);
    unawaited(_load());
  }

  Future<CommunityStore?> _store() async {
    try {
      return widget.store ?? await CommunityStore.open();
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final store = await _store();
    if (store != null) {
      try {
        await ClientNotice.load(store);
      } catch (_) {}
    }
    if (mounted) _show();
  }

  Future<void> _show() async {
    final notice = ClientNotice.current.value;
    if (notice == null) {
      if (_banner != null && mounted) setState(() => _banner = null);
      return;
    }
    final identity = ClientNotice.hash(notice);
    if (identity == _handled || identity == _resolving) return;
    _resolving = identity;
    final CommunityStore? store;
    try {
      store = await _store();
      if (store != null && await ClientNotice.shownRecently(store, notice)) {
        _handled = identity;
        return;
      }
    } finally {
      _resolving = null;
    }
    if (!mounted || ClientNotice.current.value != notice) return;
    _handled = identity;
    if (notice['level'] != 'required') {
      setState(() {
        _banner = notice;
        _bannerHidden = false;
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = communityAuthNavigatorKey.currentContext;
      if (!mounted || ctx == null) {
        _handled = null;
        return;
      }
      if (store != null) unawaited(ClientNotice.markShown(store, notice));
      showDialog<void>(
        context: ctx,
        builder: (dialog) => AlertDialog(
          title: const Text('앱 업데이트 안내'),
          content: Text(notice['message'] as String),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('확인'),
            ),
            FilledButton(
              onPressed: () => _openStore(notice),
              child: const Text('스토어 열기'),
            ),
          ],
        ),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _openStore(Map<String, Object?> notice) {
    final urls = notice['url'];
    final uri = Uri.tryParse(
      ((urls is Map ? urls['mobile'] : null) ??
              (ClientNotice.fallback['url'] as Map)['mobile'])
          as String,
    );
    if (uri != null && uri.scheme == 'https') {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
    }
  }

  Future<void> _dismissBanner(Map<String, Object?> notice) async {
    setState(() => _bannerHidden = true);
    final store = await _store();
    if (store != null) await ClientNotice.markShown(store, notice);
  }

  @override
  void dispose() {
    ClientNotice.current.removeListener(_show);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banner = _bannerHidden ? null : _banner;
    final scheme = Theme.of(context).colorScheme;
    // The tree shape never changes, so the app below keeps its state when the banner appears.
    return Column(
      children: [
        if (banner == null)
          const SizedBox.shrink()
        else
          Material(
            color: banner['level'] == 'warning'
                ? scheme.errorContainer
                : scheme.secondaryContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        banner['message'] as String,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _openStore(banner),
                      child: const Text('스토어 열기'),
                    ),
                    IconButton(
                      // No tooltip: this banner sits above the Navigator, where no Overlay exists.
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        semanticLabel: '닫기',
                      ),
                      onPressed: () => unawaited(_dismissBanner(banner)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: banner != null,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
