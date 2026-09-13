import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/yattee/yattee_video.dart';
import 'package:plezy/models/yattee/youtube_media_item.dart';

YatteeVideoSummary _summary({bool liveNow = false, bool isUpcoming = false, int lengthSeconds = 212}) =>
    YatteeVideoSummary(
      videoId: 'dQw4w9WgXcQ',
      title: 'A video',
      author: 'A channel',
      authorId: 'UC123',
      lengthSeconds: lengthSeconds,
      liveNow: liveNow,
      isUpcoming: isUpcoming,
      viewCountText: '1.2M views',
      publishedText: '3 days ago',
    );

void main() {
  group('YouTubeMediaItems.fromSummary', () {
    test('an ordinary upload carries a duration and no broadcast badge', () {
      final item = YouTubeMediaItems.fromSummary(_summary());

      expect(item.durationMs, 212000);
      expect(item.youTubeBroadcastBadge, isNull);
      expect(item.summary, '1.2M views • 3 days ago');
    });

    // A broadcast reports no length, so the poster has nothing on it that
    // says "live" unless the badge does.
    test('a live broadcast badges the poster and leads its metadata line', () {
      final item = YouTubeMediaItems.fromSummary(_summary(liveNow: true, lengthSeconds: 0));

      expect(item.durationMs, isNull);
      expect(item.youTubeBroadcastBadge, t.liveTv.live);
      expect(item.summary, startsWith(t.liveTv.live));
    });

    test('a premiere badges as upcoming', () {
      final item = YouTubeMediaItems.fromSummary(_summary(isUpcoming: true, lengthSeconds: 0));

      expect(item.youTubeBroadcastBadge, t.explore.status.upcoming);
    });

    test('a channel stand-in has no broadcast badge', () {
      final item = YouTubeMediaItems.fromChannel(const YatteeChannel(authorId: 'UC123', author: 'A channel'));

      expect(item.isYouTubeItem, isTrue);
      expect(item.youTubeBroadcastBadge, isNull);
    });
  });
}
