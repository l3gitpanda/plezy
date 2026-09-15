import 'yattee_site.dart';
import 'yattee_video.dart';

/// How far into one video this profile got, and enough of the video to draw
/// its card again without asking the server.
///
/// Yattee Server keeps no watch state of any kind — no history, no progress,
/// no mark-watched route — so a resume point cannot be stored where the
/// videos are. This is Plezy's own record: it travels with the profile, not
/// with the instance, and it carries the video summary because re-resolving
/// every partly-watched video just to title its card would be a request per
/// entry every time the tab opens.
class YatteeWatchProgress {
  final YatteeVideoSummary video;

  /// Where playback stopped.
  final int positionMs;

  /// The runtime playback actually reported, which is the authority here:
  /// the summary's `lengthSeconds` is whatever the listing claimed and is
  /// zero for a good number of rows.
  final int durationMs;

  /// When this was last written, for ordering the row most-recent-first.
  final int updatedAtMs;

  const YatteeWatchProgress({
    required this.video,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
  });

  YatteeSite get site => video.site;
  String get videoId => video.videoId;

  /// Completion in the inclusive range 0–1, or null when there is no runtime
  /// to measure against.
  double? get fraction {
    if (durationMs <= 0) return null;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  factory YatteeWatchProgress.fromJson(Map<String, Object?> json) {
    final video = json['video'];
    return YatteeWatchProgress(
      video: YatteeVideoSummary.fromJson(video is Map ? video.cast<String, dynamic>() : const {}),
      positionMs: _intOrZero(json['positionMs']),
      durationMs: _intOrZero(json['durationMs']),
      updatedAtMs: _intOrZero(json['updatedAtMs']),
    );
  }

  Map<String, Object?> toJson() => {
    'video': video.toJson(),
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAtMs': updatedAtMs,
  };

  static int _intOrZero(Object? value) => switch (value) {
    final int value => value,
    final num value => value.round(),
    final String value => int.tryParse(value) ?? 0,
    _ => 0,
  };
}
