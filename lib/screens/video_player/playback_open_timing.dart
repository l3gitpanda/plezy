/// The two time values [Player.open] takes for one playback attempt: where
/// the media should start and, when the backend cannot learn it from the
/// stream itself, how long the timeline is.
class PlaybackOpenTiming {
  final Duration? mediaStart;
  final Duration? timelineDuration;

  const PlaybackOpenTiming({this.mediaStart, this.timelineDuration});
}

/// Resolve the open-time timing for one attempt.
///
/// A live stream has neither value: its window slides, so there is no
/// position to resume from and no duration to pin the timeline to. Passing
/// either would make the player seek into — or scrub against — a range that
/// does not exist. [isLive] covers a YouTube livestream as well as live TV.
///
/// [timelineDuration] is otherwise only for transcodes: a direct-play file
/// carries its own duration, while a backend transcode's HLS manifest
/// advertises only what has been produced so far, so the item's known length
/// has to be supplied instead.
PlaybackOpenTiming playbackOpenTiming({
  required bool isTranscoding,
  required bool isLive,
  required Duration? resumePosition,
  required int? durationMs,
}) {
  if (isLive) return const PlaybackOpenTiming();
  return PlaybackOpenTiming(
    mediaStart: resumePosition,
    timelineDuration: isTranscoding && durationMs != null ? Duration(milliseconds: durationMs) : null,
  );
}
