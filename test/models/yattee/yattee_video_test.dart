import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/yattee/youtube_media_item.dart';
import 'package:plezy/models/yattee/yattee_video.dart';

/// A `VideoListItem` the way Yattee Server's InnerTube path emits it: every
/// key present, nulls for unknowns, five fixed thumbnail sizes.
Map<String, dynamic> _listItem({String id = 'dQw4w9WgXcQ', bool live = false}) => {
  'type': 'video',
  'videoId': id,
  'title': 'Never Gonna Give You Up',
  'description': null,
  'author': 'Rick Astley',
  'authorId': 'UCuAXFkgsw1L7xaCfnd5JJOw',
  'authorUrl': '/channel/UCuAXFkgsw1L7xaCfnd5JJOw',
  'lengthSeconds': 213,
  'published': 1256400000,
  'publishedText': '15 years ago',
  'viewCount': 1500000000,
  'viewCountText': '1.5B views',
  'likeCount': null,
  'videoThumbnails': [
    {'quality': 'default', 'url': 'https://i.ytimg.com/vi/$id/default.jpg', 'width': 120, 'height': 90},
    {'quality': 'medium', 'url': 'https://i.ytimg.com/vi/$id/mqdefault.jpg', 'width': 320, 'height': 180},
    {'quality': 'high', 'url': 'https://i.ytimg.com/vi/$id/hqdefault.jpg', 'width': 480, 'height': 360},
    {'quality': 'sddefault', 'url': 'https://i.ytimg.com/vi/$id/sddefault.jpg', 'width': 640, 'height': 480},
    {'quality': 'maxres', 'url': 'https://i.ytimg.com/vi/$id/maxresdefault.jpg', 'width': 1280, 'height': 720},
  ],
  'liveNow': live,
  'isUpcoming': false,
  'isShort': null,
  'extractor': 'youtube',
  'videoUrl': 'https://www.youtube.com/watch?v=$id',
};

void main() {
  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  group('YatteeVideoSummary', () {
    test('maps a VideoListItem, tolerating nulls and the fixed thumbnail ladder', () {
      final video = YatteeVideoSummary.fromJson(_listItem());
      expect(video.videoId, 'dQw4w9WgXcQ');
      expect(video.title, 'Never Gonna Give You Up');
      expect(video.author, 'Rick Astley');
      expect(video.authorId, 'UCuAXFkgsw1L7xaCfnd5JJOw');
      expect(video.lengthSeconds, 213);
      expect(video.published, 1256400000);
      expect(video.viewCount, 1500000000);
      expect(video.viewCountText, '1.5B views');
      expect(video.liveNow, isFalse);
      expect(video.isShort, isFalse);
      expect(video.thumbnails, hasLength(5));
      expect(video.thumbnail?.url, endsWith('maxresdefault.jpg'));
    });

    test('listFromJson drops entries without a video id', () {
      final videos = YatteeVideoSummary.listFromJson([
        _listItem(),
        {'type': 'video', 'title': 'broken'},
      ]);
      expect(videos, hasLength(1));
    });

    test('best thumbnail honours the width cap and unsized entries', () {
      final capped = YatteeThumbnail.best(YatteeVideoSummary.fromJson(_listItem()).thumbnails, maxWidth: 640);
      expect(capped?.url, endsWith('sddefault.jpg'));
      final unsized = YatteeThumbnail.best(const [
        YatteeThumbnail(quality: 'a', url: 'https://x/a.jpg'),
        YatteeThumbnail(quality: 'b', url: 'https://x/b.jpg'),
      ]);
      expect(unsized?.url, 'https://x/b.jpg');
    });
  });

  group('YatteeSearchResults', () {
    test('splits the mixed array by type and drops playlists', () {
      final results = YatteeSearchResults.fromJson([
        _listItem(),
        {
          'type': 'channel',
          'authorId': 'UC123',
          'author': 'Some Channel',
          'description': 'About',
          'subCount': 12000,
          'subCountText': '12K subscribers',
          'videoCount': 40,
          'authorThumbnails': [
            {'quality': '', 'url': 'https://yt3.ggpht.com/a=s88', 'width': 88, 'height': 88},
            {'quality': '', 'url': 'https://yt3.ggpht.com/a=s176', 'width': 176, 'height': 176},
          ],
          'authorVerified': true,
        },
        {'type': 'playlist', 'playlistId': 'PL1', 'title': 'Mix', 'videoCount': 3, 'videos': []},
      ]);
      expect(results.videos.map((v) => v.videoId), ['dQw4w9WgXcQ']);
      expect(results.channels, hasLength(1));
      final channel = results.channels.single;
      expect(channel.authorId, 'UC123');
      expect(channel.subCount, 12000);
      expect(channel.verified, isTrue);
      expect(channel.avatar?.url, 'https://yt3.ggpht.com/a=s176');
    });
  });

  group('YatteeFeedPage', () {
    test('reads the snake_case envelope around camelCase items', () {
      final page = YatteeFeedPage.fromJson({
        'status': 'fetching',
        'videos': [_listItem()],
        'total': 123,
        'has_more': true,
        'ready_count': 10,
        'pending_count': 2,
        'error_count': 0,
        'eta_seconds': 6,
      });
      expect(page.isFetching, isTrue);
      expect(page.videos, hasLength(1));
      expect(page.total, 123);
      expect(page.hasMore, isTrue);
      expect(page.readyCount, 10);
      expect(page.pendingCount, 2);
      expect(page.etaSeconds, 6);
    });
  });

  group('YatteeVideo', () {
    test('maps formats, adaptive formats (string bitrates) and captions', () {
      final video = YatteeVideo.fromJson({
        ..._listItem(),
        'hlsUrl': null,
        'dashUrl': '',
        'formatStreams': [
          {
            'url': 'https://yattee.example/proxy/relay?url=a&sig=s&exp=1',
            'itag': '22',
            'type': 'video/mp4; codecs="avc1.64001F, mp4a.40.2"',
            'quality': '720p',
            'container': 'mp4',
            'resolution': '720p',
            'width': 1280,
            'height': 720,
            'encoding': 'avc1.64001F',
            'size': null,
            'fps': 30,
            'httpHeaders': null,
          },
          {
            'url': 'https://yattee.example/proxy/relay?url=m3u8&sig=s&exp=1',
            'itag': 'hls-1',
            'type': 'application/vnd.apple.mpegurl',
            'container': 'hls',
          },
        ],
        'adaptiveFormats': [
          {
            'url': 'https://yattee.example/proxy/relay?url=v&sig=s&exp=1',
            'itag': '313',
            'type': 'video/webm; codecs="vp9"',
            'container': 'webm',
            'resolution': '2160p',
            'width': 3840,
            'height': 2160,
            'bitrate': '21000000',
            'clen': '123',
            'encoding': 'vp09.00.51.08',
            'fps': 30,
            'audioTrack': null,
            'audioQuality': null,
            'httpHeaders': null,
          },
          {
            'url': 'https://yattee.example/proxy/relay?url=a&sig=s&exp=1',
            'itag': '140',
            'type': 'audio/mp4; codecs="mp4a.40.2"',
            'container': 'm4a',
            'resolution': null,
            'width': null,
            'height': null,
            'bitrate': 129000.0,
            'encoding': 'mp4a.40.2',
            'audioQuality': 'AUDIO_QUALITY_MEDIUM',
            'audioTrack': {'id': 'en.4', 'displayName': 'English (original)', 'isDefault': true},
          },
        ],
        'captions': [
          {
            'label': 'English (auto-generated)',
            'languageCode': 'en',
            'url': 'https://yattee.example/api/v1/captions/dQw4w9WgXcQ/content?lang=en&auto=true&token=T',
            'auto_generated': true,
          },
          {'label': 'broken', 'languageCode': 'xx', 'url': '', 'auto_generated': false},
        ],
        'recommendedVideos': [_listItem(id: 'abcdefghijk')],
        'extractionMethod': 'hybrid',
      });
      expect(video.videoId, 'dQw4w9WgXcQ');
      expect(video.hlsUrl, isNull);
      expect(video.dashUrl, isNull);
      expect(video.formatStreams, hasLength(2));
      expect(video.formatStreams.last.isHls, isTrue);
      expect(video.adaptiveFormats, hasLength(2));
      final adaptiveVideo = video.adaptiveFormats.first;
      expect(adaptiveVideo.isVideo, isTrue);
      expect(adaptiveVideo.codecFamily, 'vp9');
      expect(adaptiveVideo.bitrate, 21000000);
      expect(adaptiveVideo.effectiveHeight, 2160);
      final audio = video.adaptiveFormats.last;
      expect(audio.isAudio, isTrue);
      expect(audio.codecFamily, 'mp4a');
      expect(audio.bitrate, 129000);
      expect(audio.audioTrack?.isOriginal, isTrue);
      // The blank-URL caption is unusable and dropped.
      expect(video.captions.map((c) => c.languageCode), ['en']);
      expect(video.captions.single.autoGenerated, isTrue);
      expect(video.recommendedVideos.single.videoId, 'abcdefghijk');
    });

    test('derives the codec family from the MIME codecs parameter when encoding is absent', () {
      const format = YatteeAdaptiveFormat(
        url: 'u',
        itag: '399',
        type: 'video/mp4; codecs="av01.0.08M.08"',
        resolution: '1080p60',
      );
      expect(format.codecFamily, 'av01');
      expect(format.effectiveHeight, 1080);
    });
  });

  group('YouTubeMediaItems', () {
    test('synthesizes a clip stand-in that round-trips its identity', () {
      final item = YouTubeMediaItems.fromSummary(YatteeVideoSummary.fromJson(_listItem()));
      expect(item.kind, MediaKind.clip);
      expect(item.serverId, isNull);
      expect(item.title, 'Never Gonna Give You Up');
      expect(item.parentTitle, 'Rick Astley');
      expect(item.summary, '1.5B views • 15 years ago');
      expect(item.durationMs, 213000);
      expect(item.thumbPath, endsWith('maxresdefault.jpg'));
      expect(item.isYouTubeItem, isTrue);
      expect(item.youTubeVideoId, 'dQw4w9WgXcQ');
      expect(item.youTubeChannelId, 'UCuAXFkgsw1L7xaCfnd5JJOw');
      expect(item.youTubeChannelName, 'Rick Astley');
    });

    test('synthesizes a channel stand-in without a video id', () {
      final item = YouTubeMediaItems.fromChannel(
        const YatteeChannel(authorId: 'UC1', author: 'Rick', subCountText: '4M subscribers'),
      );
      expect(item.kind, MediaKind.artist);
      expect(item.title, 'Rick');
      expect(item.parentTitle, '4M subscribers');
      expect(item.isYouTubeItem, isTrue);
      expect(item.youTubeVideoId, isNull);
      expect(item.youTubeChannelId, 'UC1');
    });

    test('formats compact counts the way YouTube does', () {
      expect(YouTubeMediaItems.formatCompactCount(987), '987');
      expect(YouTubeMediaItems.formatCompactCount(43210), '43K');
      expect(YouTubeMediaItems.formatCompactCount(1234567), '1.2M');
      expect(YouTubeMediaItems.formatCompactCount(2000000000), '2B');
      expect(YouTubeMediaItems.formatCompactViewCount(1500), '1.5K views');
    });
  });
}
