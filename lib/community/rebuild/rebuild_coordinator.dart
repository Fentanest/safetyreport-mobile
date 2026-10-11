import 'dart:async';

import 'community_rebuild.dart';

/// One foreground rebuild per account/dataset scope, independent of routes.
/// Screen disposal only removes listeners; it never loses the running future.
class RebuildCoordinator {
  String? _scope;
  CommunityRebuild? _current;

  CommunityRebuild attach(String scope, CommunityRebuild Function() create) {
    if (_scope == scope && _current != null) return _current!;
    final previous = _current;
    if (previous != null) {
      if (previous.isExecuting) {
        previous.requestPause('scope_changed');
        void disposeWhenIdle() {
          if (!previous.isExecuting) {
            previous.removeListener(disposeWhenIdle);
            scheduleMicrotask(previous.dispose);
          }
        }

        previous.addListener(disposeWhenIdle);
      } else {
        previous.dispose();
      }
    }
    _scope = scope;
    return _current = create();
  }
}
