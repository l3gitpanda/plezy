import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/playback_open_timing.dart';

void main() {
  group('playbackOpenTiming', () {
    test('direct play resumes at the stored position and lets the file report its length', () {
      final timing = playbackOpenTiming(
        isTranscoding: false,
        isLive: false,
        resumePosition: const Duration(minutes: 12),
        durationMs: 3600000,
      );

      expect(timing.mediaStart, const Duration(minutes: 12));
      expect(timing.timelineDuration, isNull);
    });

    test('a transcode is given the item length its manifest cannot advertise', () {
      final timing = playbackOpenTiming(
        isTranscoding: true,
        isLive: false,
        resumePosition: const Duration(minutes: 12),
        durationMs: 3600000,
      );

      expect(timing.mediaStart, const Duration(minutes: 12));
      expect(timing.timelineDuration, const Duration(hours: 1));
    });

    test('a transcode with no known length leaves the timeline unpinned', () {
      final timing = playbackOpenTiming(isTranscoding: true, isLive: false, resumePosition: null, durationMs: null);

      expect(timing.mediaStart, isNull);
      expect(timing.timelineDuration, isNull);
    });

    // A YouTube livestream arrives with both of these set — the screen's
    // metadata can carry a length and a reload resolves a resume position —
    // and neither means anything against a sliding window.
    test('live drops both, whatever the caller resolved', () {
      final timing = playbackOpenTiming(
        isTranscoding: false,
        isLive: true,
        resumePosition: const Duration(minutes: 12),
        durationMs: 3600000,
      );

      expect(timing.mediaStart, isNull);
      expect(timing.timelineDuration, isNull);
    });

    test('live wins over transcoding', () {
      final timing = playbackOpenTiming(
        isTranscoding: true,
        isLive: true,
        resumePosition: const Duration(minutes: 12),
        durationMs: 3600000,
      );

      expect(timing.mediaStart, isNull);
      expect(timing.timelineDuration, isNull);
    });
  });
}
