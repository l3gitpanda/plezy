import 'dart:async';

import '../../models/yattee/yattee_video.dart';
import 'youtube_watch_policy.dart';

/// Keeps one YouTube playback session's resume point up to date, and marks
/// the video watched once it reaches the end.
///
/// The parallel of `PlaybackProgressTracker` for the one path that has no
/// server to report to. Yattee Server stores no watch state — no history, no
/// position, no mark-watched route — so the record is Plezy's own and this is
/// what writes it.
///
/// The player is reached through position/duration callbacks rather than a
/// `Player` so the whole thing is exercisable without one; the decision
/// itself lives in [classifyYouTubeWatch].
class YouTubeWatchSession {
  YouTubeWatchSession({
    required this.video,
    required this.isLive,
    required this.positionMs,
    required this.durationMs,
    required this.onSave,
    required this.onComplete,
    this.interval = const Duration(seconds: 10),
  });

  final YatteeVideoSummary video;

  /// Broadcasts are never recorded: there is no end to finish and no position
  /// to come back to.
  final bool isLive;

  final int Function() positionMs;
  final int Function() durationMs;

  /// Persist a resume point.
  final Future<void> Function(int positionMs, int durationMs) onSave;

  /// The video reached the end: mark it watched and drop its resume point.
  final Future<void> Function() onComplete;

  final Duration interval;

  Timer? _timer;
  bool _completed = false;

  /// Whether this session already recorded the video as finished.
  bool get isComplete => _completed;

  void start() {
    if (isLive || _timer != null) return;
    // First tick at [interval], not immediately: at open the position is 0 and
    // the duration frequently still unknown, and nothing is written below the
    // resume floor anyway.
    _timer = Timer.periodic(interval, (_) => unawaited(sample()));
  }

  /// Read the player once and act on what it says.
  ///
  /// The reading is taken synchronously, before the first await, so a caller
  /// that is about to stop the player still records where playback actually
  /// was. Overlapping writes are fine: they are serialized behind the store's
  /// own queue and the later one wins, which is the later position.
  Future<void> sample() async {
    if (_completed) return;
    final position = positionMs();
    final duration = durationMs();
    switch (classifyYouTubeWatch(positionMs: position, durationMs: duration, isLive: isLive)) {
      case YouTubeWatchOutcome.ignore:
        return;
      case YouTubeWatchOutcome.save:
        await onSave(position, duration);
      case YouTubeWatchOutcome.complete:
        // Latched before the await so a tick arriving during it cannot mark
        // the same video twice.
        _completed = true;
        stop();
        await onComplete();
    }
  }

  /// Stop sampling and take one final reading — the session is ending, and
  /// where it ended is the position worth keeping.
  Future<void> flush() {
    stop();
    return sample();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
