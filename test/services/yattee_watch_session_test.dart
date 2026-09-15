import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/yattee/yattee_site.dart';
import 'package:plezy/models/yattee/yattee_video.dart';
import 'package:plezy/services/yattee/youtube_watch_session.dart';

const YatteeVideoSummary _video = YatteeVideoSummary(
  videoId: 'abc',
  title: 'A video',
  author: 'Channel',
  authorId: 'UC1',
  lengthSeconds: 3600,
);

void main() {
  const hourMs = 60 * 60 * 1000;

  ({YouTubeWatchSession session, List<int> saved, List<int> completed}) build({
    required int Function() position,
    int durationMs = hourMs,
    bool isLive = false,
  }) {
    final saved = <int>[];
    final completed = <int>[];
    final session = YouTubeWatchSession(
      video: _video,
      isLive: isLive,
      positionMs: position,
      durationMs: () => durationMs,
      onSave: (positionMs, _) async => saved.add(positionMs),
      onComplete: () async => completed.add(1),
    );
    return (session: session, saved: saved, completed: completed);
  }

  test('nothing is written before the resume floor', () {
    fakeAsync((async) {
      final harness = build(position: () => 5000);
      harness.session.start();
      async.elapse(const Duration(minutes: 1));
      expect(harness.saved, isEmpty);
      harness.session.stop();
    });
  });

  test('the resume point follows playback', () {
    fakeAsync((async) {
      var positionMs = 0;
      final harness = build(position: () => positionMs);
      harness.session.start();
      for (var tick = 1; tick <= 3; tick++) {
        positionMs = tick * 60 * 1000;
        async.elapse(const Duration(seconds: 10));
      }
      expect(harness.saved, [60000, 120000, 180000]);
      harness.session.stop();
    });
  });

  test('reaching the end marks it complete once and stops sampling', () {
    fakeAsync((async) {
      var positionMs = hourMs ~/ 2;
      final harness = build(position: () => positionMs);
      harness.session.start();
      async.elapse(const Duration(seconds: 10));
      expect(harness.saved, [hourMs ~/ 2]);

      positionMs = hourMs - 1000;
      async.elapse(const Duration(seconds: 10));
      expect(harness.completed, hasLength(1));
      expect(harness.session.isComplete, isTrue);

      // The timer is gone, so no later tick can record the same finish twice.
      async.elapse(const Duration(minutes: 5));
      expect(harness.completed, hasLength(1));
      expect(harness.saved, [hourMs ~/ 2]);
    });
  });

  test('a finished session records nothing more, even on flush', () {
    fakeAsync((async) {
      var positionMs = hourMs - 1000;
      final harness = build(position: () => positionMs);
      harness.session.start();
      async.elapse(const Duration(seconds: 10));
      expect(harness.completed, hasLength(1));

      // Rewinding after the credits must not resurrect a resume point for a
      // video the profile has already been told is watched.
      positionMs = hourMs ~/ 4;
      harness.session.flush();
      async.flushMicrotasks();
      expect(harness.saved, isEmpty);
      expect(harness.completed, hasLength(1));
    });
  });

  test('the terminal flush keeps where playback actually stopped', () {
    fakeAsync((async) {
      var positionMs = 0;
      final harness = build(position: () => positionMs);
      harness.session.start();
      // Stopped between ticks: the flush is the only thing that sees this.
      positionMs = 7 * 60 * 1000;
      harness.session.flush();
      async.flushMicrotasks();
      expect(harness.saved, [7 * 60 * 1000]);
    });
  });

  test('a broadcast never starts sampling', () {
    fakeAsync((async) {
      final harness = build(position: () => hourMs ~/ 2, isLive: true);
      harness.session.start();
      async.elapse(const Duration(minutes: 10));
      harness.session.flush();
      async.flushMicrotasks();
      expect(harness.saved, isEmpty);
      expect(harness.completed, isEmpty);
    });
  });

  test('site and id come from the video the session was built for', () {
    final harness = build(position: () => 0);
    expect(harness.session.video.site, YatteeSite.youtube);
    expect(harness.session.video.videoId, 'abc');
  });
}
