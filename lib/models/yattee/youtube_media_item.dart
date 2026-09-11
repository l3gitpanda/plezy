import '../../i18n/strings.g.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../utils/formatters.dart';
import 'yattee_video.dart';

/// Builds the rendering-only [MediaItem] stand-ins the YouTube tab feeds
/// into the shared shelf/card stack, and recognizes them again on the way
/// back (taps, long-presses, the player's metadata).
///
/// Same shape as `CatalogItem.toMediaItem`: no server id, an absolute
/// thumbnail URL, and a `raw` marker so the tap sinks can route to the
/// YouTube flow instead of a server-backed detail screen.
abstract final class YouTubeMediaItems {
  /// `raw` key under which the source [YatteeVideoSummary]'s identity lives.
  static const String rawKey = 'plezyYouTube';

  static MediaItem fromSummary(YatteeVideoSummary video) {
    final thumbnail = video.thumbnail;
    return MediaItem(
      id: 'youtube:${video.videoId}',
      // A backend is mandatory on the union; Plex is the catalog convention
      // for synthetic items and nothing downstream reads it without a
      // server id.
      backend: MediaBackend.plex,
      kind: MediaKind.clip,
      title: video.title,
      // The card's default subtitle line is `parentTitle`, which is where a
      // clip's channel name belongs.
      parentTitle: video.author,
      summary: metadataLine(video),
      durationMs: video.lengthSeconds > 0 ? video.lengthSeconds * 1000 : null,
      thumbPath: thumbnail?.url,
      artPath: thumbnail?.url,
      raw: {
        rawKey: {'videoId': video.videoId, 'channelId': video.authorId, 'channel': video.author},
      },
    );
  }

  /// A channel search hit as a square-card stand-in: the avatar where a
  /// music artist's portrait would go, the subscriber count as the subtitle.
  static MediaItem fromChannel(YatteeChannel channel) {
    return MediaItem(
      id: 'youtube-channel:${channel.authorId}',
      backend: MediaBackend.plex,
      kind: MediaKind.artist,
      title: channel.author,
      parentTitle: channel.subCountText,
      summary: channel.description,
      thumbPath: channel.avatar?.url,
      raw: {
        rawKey: {'channelId': channel.authorId, 'channel': channel.author},
      },
    );
  }

  /// "1.2M views • 3 days ago", from whichever of the server's text/numeric
  /// fields is present. Live and upcoming rows carry no view count.
  static String? metadataLine(YatteeVideoSummary video) {
    final parts = <String>[
      if (video.viewCountText case final text? when text.isNotEmpty)
        text
      else if (video.viewCount case final count?)
        formatCompactViewCount(count),
      if (video.publishedText case final text? when text.isNotEmpty)
        text
      else if (video.published case final epoch?)
        formatRelativeDayLabel(DateTime.fromMillisecondsSinceEpoch(epoch * 1000)),
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }

  /// `1.2M views`; YouTube's own abbreviation scale.
  static String formatCompactViewCount(int count) => t.yattee.views(count: formatCompactCount(count));

  /// `1.2M`, `43K`, `987`.
  static String formatCompactCount(int count) {
    if (count >= 1000000000) return '${_trim(count / 1000000000)}B';
    if (count >= 1000000) return '${_trim(count / 1000000)}M';
    if (count >= 1000) return '${_trim(count / 1000)}K';
    return '$count';
  }

  static String _trim(double value) {
    final text = value >= 10 ? value.round().toString() : value.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }
}

/// Recognizes [MediaItem]s synthesized by [YouTubeMediaItems].
extension YouTubeMediaItemX on MediaItem {
  bool get isYouTubeItem => raw?[YouTubeMediaItems.rawKey] != null;

  Map<String, Object?>? get _youTube {
    final data = raw?[YouTubeMediaItems.rawKey];
    return data is Map ? data.cast<String, Object?>() : null;
  }

  /// Null for channel stand-ins.
  String? get youTubeVideoId => _youTube?['videoId'] as String?;

  String? get youTubeChannelId => _youTube?['channelId'] as String?;

  String? get youTubeChannelName => _youTube?['channel'] as String?;
}
