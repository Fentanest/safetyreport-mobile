import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 처리중 카드가 공유하는 현지 달력 날짜. 화면에 구독자가 있을 때만
/// 자정 타이머 하나와 앱 복귀 관찰자를 유지한다.
class CurrentDay extends ChangeNotifier
    with WidgetsBindingObserver
    implements ValueListenable<DateTime> {
  static final shared = CurrentDay();

  CurrentDay({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  DateTime? _day;
  Timer? _midnight;
  bool _observing = false;

  static DateTime _dateOf(DateTime now) => now.isUtc
      ? DateTime.utc(now.year, now.month, now.day)
      : DateTime(now.year, now.month, now.day);

  @override
  DateTime get value {
    if (!hasListeners) _day = _dateOf(_now());
    return _day!;
  }

  @override
  void addListener(VoidCallback listener) {
    assert(ChangeNotifier.debugAssertNotDisposed(this));
    final first = !hasListeners;
    final previouslyRead = _day;
    final now = first ? _now() : null;
    if (first) {
      _day = _dateOf(now!);
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    super.addListener(listener);
    if (first) {
      _scheduleMidnight(now!);
      // ValueListenableBuilder의 첫 value 읽기와 구독 사이에도 자정이 지날 수 있다.
      if (previouslyRead != null && previouslyRead != _day) notifyListeners();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _stop();
  }

  bool get _background => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.paused ||
    AppLifecycleState.hidden ||
    AppLifecycleState.detached => true,
    _ => false,
  };

  void _scheduleMidnight(DateTime now) {
    _midnight?.cancel();
    _midnight = null;
    if (!hasListeners || _background) return;
    // 24시간을 더하면 DST 전환 때 현지 자정과 어긋나므로 다음 날짜를 만든다.
    final tomorrow = now.isUtc
        ? DateTime.utc(now.year, now.month, now.day + 1)
        : DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(tomorrow.difference(now), _refresh);
  }

  void _refresh() {
    final now = _now();
    final next = _dateOf(now);
    if (_day != next) {
      _day = next;
      notifyListeners();
    }
    // 마지막 구독자가 알림을 받는 중 해제한 경우도 정리한다.
    if (!hasListeners) {
      _stop();
      return;
    }
    _scheduleMidnight(now);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _midnight?.cancel();
      _midnight = null;
    }
  }

  void _stop() {
    _midnight?.cancel();
    _midnight = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}
