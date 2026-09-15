import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/yattee/youtube_watch_policy.dart';

void main() {
  const hourMs = 60 * 60 * 1000;

  YouTubeWatchOutcome classify(int positionMs, int durationMs, {bool isLive = false}) =>
      classifyYouTubeWatch(positionMs: positionMs, durationMs: durationMs, isLive: isLive);

  group('classifyYouTubeWatch', () {
    test('a glance at the first seconds is not a resume point', () {
      expect(classify(4000, hourMs), YouTubeWatchOutcome.ignore);
      expect(classify(youTubeResumeFloor.inMilliseconds - 1, hourMs), YouTubeWatchOutcome.ignore);
    });

    test('the resume floor is inclusive', () {
      expect(classify(youTubeResumeFloor.inMilliseconds, hourMs), YouTubeWatchOutcome.save);
    });

    test('the middle of a video is a resume point', () {
      expect(classify(hourMs ~/ 2, hourMs), YouTubeWatchOutcome.save);
    });

    test('crossing the threshold finishes it', () {
      expect(classify((hourMs * youTubeWatchedThreshold).round(), hourMs), YouTubeWatchOutcome.complete);
    });

    // The threshold is a fraction and nothing else, exactly as it is for a
    // server-backed item: the last minutes of a short video are still short
    // of it, so nothing is finished early.
    test('just under the threshold is still a resume point', () {
      expect(classify((hourMs * youTubeWatchedThreshold).round() - 1000, hourMs), YouTubeWatchOutcome.save);
      // A five-minute video two minutes from its end is nowhere near watched.
      const fiveMinutes = 5 * 60 * 1000;
      expect(classify(3 * 60 * 1000, fiveMinutes), YouTubeWatchOutcome.save);
    });

    test('a broadcast is never recorded', () {
      // Live "duration" is however much of the window is buffered, which would
      // otherwise read as finished almost immediately.
      expect(classify(hourMs, hourMs, isLive: true), YouTubeWatchOutcome.ignore);
      expect(classify(hourMs ~/ 2, hourMs, isLive: true), YouTubeWatchOutcome.ignore);
    });

    test('an unknown runtime has nothing to measure against', () {
      expect(classify(hourMs ~/ 2, 0), YouTubeWatchOutcome.ignore);
      expect(classify(hourMs ~/ 2, -1), YouTubeWatchOutcome.ignore);
    });

    test('a negative position is ignored rather than stored', () {
      expect(classify(-1, hourMs), YouTubeWatchOutcome.ignore);
    });
  });
}
