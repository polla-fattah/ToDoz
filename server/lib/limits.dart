/// Abuse limits (SEC-8): a sliding-window rate limiter and a lockout for
/// repeated failures. In memory, which is fine for one small server process.
library;

class RateLimiter {
  RateLimiter({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;
  final _hits = <String, List<DateTime>>{};

  /// Records a hit for [key] and says whether it is within [limit] hits per [window].
  bool allow(String key, {required int limit, required Duration window}) {
    final now = _now();
    final list = _hits.putIfAbsent(key, () => []);
    list.removeWhere((t) => now.difference(t) >= window);
    if (list.length >= limit) return false;
    list.add(now);
    if (_hits.length > 10000) _hits.removeWhere((k, v) => v.isEmpty || now.difference(v.last) >= window);
    return true;
  }
}

/// Blocks a source after too many failures in a window.
class FailureLockout {
  FailureLockout({this.maxFailures = 5, this.window = const Duration(minutes: 15), DateTime Function()? clock})
      : _now = clock ?? DateTime.now;

  final int maxFailures;
  final Duration window;
  final DateTime Function() _now;
  final _failures = <String, List<DateTime>>{};

  bool isLocked(String key) {
    final list = _failures[key];
    if (list == null) return false;
    final now = _now();
    list.removeWhere((t) => now.difference(t) >= window);
    return list.length >= maxFailures;
  }

  void recordFailure(String key) => _failures.putIfAbsent(key, () => []).add(_now());

  void reset(String key) => _failures.remove(key);
}
