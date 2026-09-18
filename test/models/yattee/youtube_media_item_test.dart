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
      thumbnails: const [
        YatteeThumbnail(
          quality: 'maxres',
          url: 'https://static-cdn.jtvnw.net/previews-ttv/live_user_xqc-1280x720.jpg',
          width: 1280,
          height: 720,
        ),
      ],
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

    test('an upload shows its runtime in YouTube\'s mm:ss form', () {
      expect(YouTubeMediaItems.fromSummary(_summary()).youTubeDurationLabel, '3:32');
      expect(YouTubeMediaItems.fromSummary(_summary(lengthSeconds: 3725)).youTubeDurationLabel, '1:02:05');
    });

    // A live broadcast and an unstarted premiere both report zero, and a
    // runtime badge on either would be a lie — the LIVE badge speaks instead.
    test('a broadcast shows no runtime', () {
      expect(YouTubeMediaItems.fromSummary(_summary(liveNow: true, lengthSeconds: 0)).youTubeDurationLabel, isNull);
      expect(YouTubeMediaItems.fromSummary(_summary(isUpcoming: true, lengthSeconds: 0)).youTubeDurationLabel, isNull);
    });

    // Twitch serves a broadcast's preview from a fixed path — the picture
    // changes, the address does not — so the image cache, which keys on URL,
    // would hold the first frame it ever fetched.
    test('a live preview is cache-busted on a coarse interval', () {
      final at = DateTime.utc(2026, 9, 14, 12, 0);
      final item = YouTubeMediaItems.fromSummary(_summary(liveNow: true, lengthSeconds: 0), now: at);
      final later = YouTubeMediaItems.fromSummary(
        _summary(liveNow: true, lengthSeconds: 0),
        now: at.add(const Duration(minutes: 6)),
      );
      final sameBucket = YouTubeMediaItems.fromSummary(
        _summary(liveNow: true, lengthSeconds: 0),
        now: at.add(const Duration(minutes: 1)),
      );

      expect(item.thumbPath, isNot(later.thumbPath), reason: 'a later interval refetches');
      expect(item.thumbPath, sameBucket.thumbPath, reason: 'within one interval the cache is reused');
    });

    test('a finished upload keeps its URL untouched', () {
      final item = YouTubeMediaItems.fromSummary(_summary(), now: DateTime.utc(2026, 9, 14));
      expect(item.thumbPath, isNot(contains('plezy=')));
    });

    test('an unparseable thumbnail URL is left alone rather than mangled', () {
      expect(YouTubeMediaItems.livePreviewUrl('::not a url::', DateTime.utc(2026)), '::not a url::');
    });

    test('a channel stand-in has no broadcast badge', () {
      final item = YouTubeMediaItems.fromChannel(const YatteeChannel(authorId: 'UC123', author: 'A channel'));

      expect(item.isYouTubeItem, isTrue);
      expect(item.youTubeBroadcastBadge, isNull);
      expect(item.youTubeDurationLabel, isNull);
    });
  });
}
