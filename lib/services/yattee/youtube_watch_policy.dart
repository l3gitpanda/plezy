import '../../media/watch_progress.dart';

/// What one position sample means for a YouTube video's stored resume point.
enum YouTubeWatchOutcome {
  /// Leave the store alone: too early to be a resume point, or nothing
  /// meaningful to record.
  ignore,

  /// Write (or update) the resume point at this position.
  save,

  /// Far enough through to count as finished: mark the video watched and
  /// drop its resume point.
  complete,
}

/// The fraction of a video that counts as having watched it.
///
/// Media servers each publish their own (`MediaServerClient.watchedThreshold`)
/// and there is no server here to ask, so the YouTube path states its own.
/// 0.9 matches what the backends Plezy talks to settle on and is forgiving of
/// the end-cards and outros a video's last minute is usually made of.
const double youTubeWatchedThreshold = 0.9;

/// How far in a resume point becomes worth keeping. Below this the user
/// opened the video and changed their mind, and offering to resume 4 seconds
/// in is worse than offering nothing.
const Duration youTubeResumeFloor = Duration(seconds: 20);

/// Classify one position sample.
///
/// Pure, so the boundaries are testable without a player: every caller passes
/// what it observed and acts on the answer.
///
/// [isLive] videos are always ignored. A broadcast has no end to be finished
/// at and no position to come back to — its "duration" is however much of the
/// window the player has buffered, which would read as 100% watched almost
/// immediately.
YouTubeWatchOutcome classifyYouTubeWatch({
  required int positionMs,
  required int durationMs,
  required bool isLive,
  double threshold = youTubeWatchedThreshold,
}) {
  if (isLive || durationMs <= 0 || positionMs < 0) return YouTubeWatchOutcome.ignore;
  if (isWatchedProgress(positionMs: positionMs, durationMs: durationMs, threshold: threshold)) {
    return YouTubeWatchOutcome.complete;
  }
  if (positionMs < youTubeResumeFloor.inMilliseconds) return YouTubeWatchOutcome.ignore;
  return YouTubeWatchOutcome.save;
}
