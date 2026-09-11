import '../../utils/json_utils.dart';

/// One entry of an Invidious-style thumbnail list.
class YatteeThumbnail {
  final String quality;
  final String url;
  final int? width;
  final int? height;

  const YatteeThumbnail({required this.quality, required this.url, this.width, this.height});

  factory YatteeThumbnail.fromJson(Map<String, dynamic> json) => YatteeThumbnail(
    quality: stringOrEmpty(json['quality']),
    url: stringOrEmpty(json['url']),
    width: flexibleInt(json['width']),
    height: flexibleInt(json['height']),
  );

  static List<YatteeThumbnail> listFromJson(Object? value) => parseFlexibleJsonList(value, YatteeThumbnail.fromJson);

  /// The largest thumbnail no wider than [maxWidth], falling back to the
  /// widest one available. Sizes are absent on some Invidious-sourced lists,
  /// so an unsized entry ranks by its position in the (ascending) list.
  static YatteeThumbnail? best(List<YatteeThumbnail> thumbnails, {int maxWidth = 1280}) {
    if (thumbnails.isEmpty) return null;
    YatteeThumbnail? fit;
    for (final thumbnail in thumbnails) {
      if (thumbnail.url.isEmpty) continue;
      final width = thumbnail.width;
      if (width != null && width > maxWidth) continue;
      if (fit == null || (width ?? 0) >= (fit.width ?? 0)) fit = thumbnail;
    }
    return fit ?? thumbnails.lastWhere((t) => t.url.isNotEmpty, orElse: () => thumbnails.last);
  }
}

/// A video row as listed by the feed, trending, popular, search and channel
/// endpoints (`VideoListItem` in Yattee Server's models).
class YatteeVideoSummary {
  final String videoId;
  final String title;
  final String? description;
  final String author;
  final String authorId;
  final int lengthSeconds;

  /// Unix seconds; null when the backend only had a relative text.
  final int? published;
  final String? publishedText;
  final int? viewCount;
  final String? viewCountText;
  final List<YatteeThumbnail> thumbnails;
  final bool liveNow;
  final bool isUpcoming;
  final bool isShort;

  const YatteeVideoSummary({
    required this.videoId,
    required this.title,
    this.description,
    required this.author,
    required this.authorId,
    required this.lengthSeconds,
    this.published,
    this.publishedText,
    this.viewCount,
    this.viewCountText,
    this.thumbnails = const [],
    this.liveNow = false,
    this.isUpcoming = false,
    this.isShort = false,
  });

  factory YatteeVideoSummary.fromJson(Map<String, dynamic> json) => YatteeVideoSummary(
    videoId: stringOrEmpty(json['videoId']),
    title: stringOrEmpty(json['title']),
    description: json['description'] as String?,
    author: stringOrEmpty(json['author']),
    authorId: stringOrEmpty(json['authorId']),
    lengthSeconds: flexibleIntOrZero(json['lengthSeconds']),
    published: flexibleInt(json['published']),
    publishedText: json['publishedText'] as String?,
    viewCount: flexibleInt(json['viewCount']),
    viewCountText: json['viewCountText'] as String?,
    thumbnails: YatteeThumbnail.listFromJson(json['videoThumbnails']),
    liveNow: flexibleBool(json['liveNow']),
    isUpcoming: flexibleBool(json['isUpcoming']),
    isShort: flexibleBool(json['isShort']),
  );

  static List<YatteeVideoSummary> listFromJson(Object? value) =>
      parseFlexibleJsonList(value, YatteeVideoSummary.fromJson).where((v) => v.videoId.isNotEmpty).toList();

  YatteeThumbnail? get thumbnail => YatteeThumbnail.best(thumbnails);
}

/// A channel as returned by `/channels/{id}` and by `type: channel` search
/// hits. Search hits omit `totalViews` and the banners.
class YatteeChannel {
  final String authorId;
  final String author;
  final String? description;
  final int? subCount;
  final String? subCountText;
  final int? totalViews;
  final List<YatteeThumbnail> thumbnails;
  final List<YatteeThumbnail> banners;
  final bool verified;

  const YatteeChannel({
    required this.authorId,
    required this.author,
    this.description,
    this.subCount,
    this.subCountText,
    this.totalViews,
    this.thumbnails = const [],
    this.banners = const [],
    this.verified = false,
  });

  factory YatteeChannel.fromJson(Map<String, dynamic> json) => YatteeChannel(
    authorId: stringOrEmpty(json['authorId']),
    author: stringOrEmpty(json['author']),
    description: json['description'] as String?,
    subCount: flexibleInt(json['subCount']),
    subCountText: json['subCountText'] as String?,
    totalViews: flexibleInt(json['totalViews']),
    thumbnails: YatteeThumbnail.listFromJson(json['authorThumbnails']),
    banners: YatteeThumbnail.listFromJson(json['authorBanners']),
    verified: flexibleBool(json['authorVerified']),
  );

  /// Channel avatars are listed smallest first; the largest is still tiny
  /// (512px), so no width cap is needed.
  YatteeThumbnail? get avatar => YatteeThumbnail.best(thumbnails, maxWidth: 1 << 16);
}

/// One page of a channel's uploads. [continuation] is an opaque backend
/// cursor to echo back; null once the listing is exhausted.
class YatteeChannelVideosPage {
  final List<YatteeVideoSummary> videos;
  final String? continuation;

  const YatteeChannelVideosPage({required this.videos, this.continuation});

  factory YatteeChannelVideosPage.fromJson(Map<String, dynamic> json) => YatteeChannelVideosPage(
    videos: YatteeVideoSummary.listFromJson(json['videos']),
    continuation: json['continuation']?.toString(),
  );
}

/// `/search` answers one mixed array discriminated by `type`; playlists are
/// out of scope and dropped here.
class YatteeSearchResults {
  final List<YatteeVideoSummary> videos;
  final List<YatteeChannel> channels;

  const YatteeSearchResults({this.videos = const [], this.channels = const []});

  factory YatteeSearchResults.fromJson(Object? value) {
    final videos = <YatteeVideoSummary>[];
    final channels = <YatteeChannel>[];
    for (final entry in flexibleMapList(value)) {
      switch (entry['type']) {
        case 'video':
          final video = YatteeVideoSummary.fromJson(entry);
          if (video.videoId.isNotEmpty) videos.add(video);
        case 'channel':
          final channel = YatteeChannel.fromJson(entry);
          if (channel.authorId.isNotEmpty) channels.add(channel);
      }
    }
    return YatteeSearchResults(videos: videos, channels: channels);
  }

  bool get isEmpty => videos.isEmpty && channels.isEmpty;
}

/// `POST /feed` response. The server answers from its cache and reports
/// `fetching` while channels it has never seen are still being crawled, so
/// a first load may be partial — see [readyCount]/[pendingCount].
class YatteeFeedPage {
  final String status;
  final List<YatteeVideoSummary> videos;
  final int total;
  final bool hasMore;
  final int readyCount;
  final int pendingCount;
  final int errorCount;
  final int? etaSeconds;

  const YatteeFeedPage({
    required this.status,
    required this.videos,
    required this.total,
    required this.hasMore,
    this.readyCount = 0,
    this.pendingCount = 0,
    this.errorCount = 0,
    this.etaSeconds,
  });

  factory YatteeFeedPage.fromJson(Map<String, dynamic> json) => YatteeFeedPage(
    status: stringOrEmpty(json['status']),
    videos: YatteeVideoSummary.listFromJson(json['videos']),
    total: flexibleIntOrZero(json['total']),
    hasMore: flexibleBool(json['has_more']),
    readyCount: flexibleIntOrZero(json['ready_count']),
    pendingCount: flexibleIntOrZero(json['pending_count']),
    errorCount: flexibleIntOrZero(json['error_count']),
    etaSeconds: flexibleInt(json['eta_seconds']),
  );

  bool get isFetching => status == 'fetching' || pendingCount > 0;
}

/// A muxed (video+audio) progressive stream. YouTube caps these at 720p, so
/// they are only a fallback when no adaptive pair can be built.
class YatteeFormatStream {
  final String url;
  final String itag;

  /// Full MIME type with a `codecs="…"` parameter, e.g.
  /// `video/mp4; codecs="avc1.64001F, mp4a.40.2"`.
  final String type;
  final String? container;
  final String? resolution;
  final int? width;
  final int? height;
  final int? fps;
  final Map<String, String>? httpHeaders;

  const YatteeFormatStream({
    required this.url,
    required this.itag,
    required this.type,
    this.container,
    this.resolution,
    this.width,
    this.height,
    this.fps,
    this.httpHeaders,
  });

  factory YatteeFormatStream.fromJson(Map<String, dynamic> json) => YatteeFormatStream(
    url: stringOrEmpty(json['url']),
    itag: stringOrEmpty(json['itag']),
    type: stringOrEmpty(json['type']),
    container: json['container']?.toString(),
    resolution: json['resolution']?.toString(),
    width: flexibleInt(json['width']),
    height: flexibleInt(json['height']),
    fps: flexibleInt(json['fps']),
    httpHeaders: _headersFromJson(json['httpHeaders']),
  );

  /// yt-dlp lists HLS variants among the muxed formats; they are manifests,
  /// not files, and only useful for live streams.
  bool get isHls => container == 'hls' || type.startsWith('application/');
}

/// Which audio track an adaptive audio format belongs to on multi-language
/// (dubbed) uploads. Absent on single-track videos.
class YatteeAudioTrack {
  final String? id;
  final String? displayName;
  final bool isDefault;

  const YatteeAudioTrack({this.id, this.displayName, this.isDefault = false});

  factory YatteeAudioTrack.fromJson(Map<String, dynamic> json) => YatteeAudioTrack(
    id: json['id']?.toString(),
    displayName: json['displayName']?.toString(),
    isDefault: flexibleBool(json['isDefault']),
  );

  /// YouTube marks the upload's own language as "original" in the display
  /// name; the `isDefault` flag is not always set alongside it.
  bool get isOriginal => isDefault || (displayName?.toLowerCase().contains('original') ?? false);
}

/// One DASH-style adaptive format: video-only or audio-only. Full-resolution
/// playback pairs the best of each.
class YatteeAdaptiveFormat {
  final String url;
  final String itag;
  final String type;
  final String? container;
  final String? resolution;
  final int? width;
  final int? height;

  /// Bits per second (InnerTube) or `tbr*1000` (yt-dlp); either way the
  /// higher the better within one codec.
  final int? bitrate;
  final int? fps;

  /// Codec name (`avc1.64002a`, `vp09.00.51.08`, `av01…`, `opus`, `mp4a.40.2`).
  final String? encoding;
  final String? audioQuality;
  final YatteeAudioTrack? audioTrack;
  final Map<String, String>? httpHeaders;

  const YatteeAdaptiveFormat({
    required this.url,
    required this.itag,
    required this.type,
    this.container,
    this.resolution,
    this.width,
    this.height,
    this.bitrate,
    this.fps,
    this.encoding,
    this.audioQuality,
    this.audioTrack,
    this.httpHeaders,
  });

  factory YatteeAdaptiveFormat.fromJson(Map<String, dynamic> json) => YatteeAdaptiveFormat(
    url: stringOrEmpty(json['url']),
    itag: stringOrEmpty(json['itag']),
    type: stringOrEmpty(json['type']),
    container: json['container']?.toString(),
    resolution: json['resolution']?.toString(),
    width: flexibleInt(json['width']),
    height: flexibleInt(json['height']),
    bitrate: flexibleDouble(json['bitrate'])?.round(),
    fps: flexibleInt(json['fps']),
    encoding: json['encoding']?.toString(),
    audioQuality: json['audioQuality']?.toString(),
    audioTrack: parseFlexibleJsonObject(json['audioTrack'], YatteeAudioTrack.fromJson),
    httpHeaders: _headersFromJson(json['httpHeaders']),
  );

  bool get isVideo => type.startsWith('video/');

  bool get isAudio => type.startsWith('audio/');

  /// The codec family, lower-cased, from [encoding] or the MIME `codecs`
  /// parameter: `avc1`, `vp9`/`vp09`, `av01`, `mp4a`, `opus`, …
  String get codecFamily {
    final source = (encoding?.isNotEmpty ?? false) ? encoding! : _codecsParameter(type) ?? '';
    final family = source.split(RegExp(r'[.\s,]')).first.toLowerCase();
    return family == 'vp09' ? 'vp9' : family;
  }

  /// Height parsed from [height] or from `resolution` (`1080p`, `1080p60`).
  int? get effectiveHeight => height ?? _heightFromResolution(resolution);
}

/// A caption track. [url] is a signed, token-gated WebVTT URL usable without
/// Basic Auth — handed to the player as-is.
class YatteeCaption {
  final String label;
  final String languageCode;
  final String url;
  final bool autoGenerated;

  const YatteeCaption({required this.label, required this.languageCode, required this.url, this.autoGenerated = false});

  factory YatteeCaption.fromJson(Map<String, dynamic> json) => YatteeCaption(
    label: stringOrEmpty(json['label']),
    languageCode: stringOrEmpty(json['languageCode'] ?? json['language_code']),
    url: stringOrEmpty(json['url']),
    autoGenerated: flexibleBool(json['auto_generated'] ?? json['autoGenerated']),
  );
}

/// `/videos/{id}`: everything needed to play one video.
class YatteeVideo {
  final YatteeVideoSummary summary;
  final String? hlsUrl;
  final String? dashUrl;
  final List<YatteeFormatStream> formatStreams;
  final List<YatteeAdaptiveFormat> adaptiveFormats;
  final List<YatteeCaption> captions;
  final List<YatteeVideoSummary> recommendedVideos;

  const YatteeVideo({
    required this.summary,
    this.hlsUrl,
    this.dashUrl,
    this.formatStreams = const [],
    this.adaptiveFormats = const [],
    this.captions = const [],
    this.recommendedVideos = const [],
  });

  factory YatteeVideo.fromJson(Map<String, dynamic> json) => YatteeVideo(
    summary: YatteeVideoSummary.fromJson(json),
    hlsUrl: _nonBlank(json['hlsUrl']),
    dashUrl: _nonBlank(json['dashUrl']),
    formatStreams: parseFlexibleJsonList(json['formatStreams'], YatteeFormatStream.fromJson),
    adaptiveFormats: parseFlexibleJsonList(json['adaptiveFormats'], YatteeAdaptiveFormat.fromJson),
    captions: parseFlexibleJsonList(
      json['captions'],
      YatteeCaption.fromJson,
    ).where((caption) => caption.url.isNotEmpty).toList(),
    recommendedVideos: YatteeVideoSummary.listFromJson(json['recommendedVideos']),
  );

  String get videoId => summary.videoId;

  String get title => summary.title;
}

/// `name`/`version` from `/info`. The name is how a Yattee Server is told
/// apart from an Invidious instance or an unrelated web server.
class YatteeServerInfo {
  final String name;
  final String version;

  const YatteeServerInfo({required this.name, required this.version});

  factory YatteeServerInfo.fromJson(Map<String, dynamic> json) =>
      YatteeServerInfo(name: stringOrEmpty(json['name']), version: stringOrEmpty(json['version']));

  bool get isYatteeServer => name.toLowerCase().contains('yattee');
}

Map<String, String>? _headersFromJson(Object? value) {
  if (value is! Map || value.isEmpty) return null;
  return {for (final entry in value.entries) entry.key.toString(): entry.value.toString()};
}

String? _nonBlank(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String? _codecsParameter(String mimeType) {
  final match = RegExp(r'codecs="?([^";]+)"?').firstMatch(mimeType);
  return match?.group(1)?.trim();
}

int? _heightFromResolution(String? resolution) {
  if (resolution == null) return null;
  final match = RegExp(r'^(\d+)p').firstMatch(resolution.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}
