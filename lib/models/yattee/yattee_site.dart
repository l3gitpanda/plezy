import '../../utils/app_logger.dart';

/// A content source a Yattee Server can serve.
///
/// The server's API splits along this line, and the split is not cosmetic:
///
///   * The Invidious-compatible routes — `/trending`, `/popular`, `/search`,
///     `/channels/{id}`, `/videos/{id}` — are YouTube-only. They take no site
///     parameter at all, and `/videos/{id}` opens by asserting
///     `validate_extractor_allowed("youtube")` (routers/videos.py).
///   * `POST /feed` and the `/extract` routes are generic: they identify
///     content by URL and run whichever yt-dlp extractor matches, so any
///     enabled site works there.
///
/// So a non-YouTube site gets subscriptions and playback, but no browse rows
/// and no search — hence [supportsSearch], which the UI reads rather than
/// special-casing YouTube by name.
enum YatteeSite {
  /// The server's `site` id is the lowercase extractor name, matching the
  /// ids in its admin site registry (`routers/admin/sites.py`).
  youtube('youtube', supportsSearch: true, browsesByChannel: false),
  twitch('twitch', supportsSearch: false, browsesByChannel: true);

  const YatteeSite(this.id, {required this.supportsSearch, required this.browsesByChannel});

  final String id;

  /// Whether the Invidious-compatible catalog routes serve this site.
  final bool supportsSearch;

  /// Whether this site's row is built by extracting each channel rather than
  /// by asking the feed.
  ///
  /// The feed cannot answer "is this channel live". `FeedVideoResponse`
  /// carries no live flag — the field is absent from the model, and
  /// `cached_videos` has no column to hold one — and it serves whatever
  /// thumbnail was stored when the channel was first crawled, so a live
  /// preview freezes at the moment of subscribing.
  ///
  /// `/extract/channel` answers with `VideoListItem`, which yt-dlp does
  /// populate with `liveNow`, and with a thumbnail from this moment. It costs
  /// one extraction per channel, which is why only a site whose channels
  /// *are* broadcasts pays it.
  final bool browsesByChannel;

  /// The site this feed item or subscription belongs to.
  ///
  /// The server reports it as the `extractor` field, which for feed rows is
  /// the stored `site` column (routers/subscriptions.py). Unknown extractors
  /// fall back to [youtube]: every pre-existing subscription predates this
  /// field, and they are all YouTube.
  static YatteeSite fromId(String? id) {
    if (id == null || id.isEmpty) return YatteeSite.youtube;
    final normalized = id.toLowerCase();
    for (final site in YatteeSite.values) {
      // Matched by family, not by equality. yt-dlp names an extractor for the
      // thing it extracts, not the site: a Twitch broadcast reports
      // `twitch:stream` and a past one `twitch:vod`. Yattee Server matches the
      // same way — `get_site_by_extractor` does `re.search("twitch", extractor)`
      // — so an exact comparison here disagreed with the server about what
      // site a video came from, and every Twitch item fell through to the
      // YouTube default below.
      if (normalized == site.id || normalized.startsWith('${site.id}:')) return site;
    }
    // An extractor this build has no row for. Reading it as YouTube is right
    // for the rows that predate the field — they are all YouTube — but it is
    // a guess for anything else, so say so where it can be seen.
    appLogger.w('Yattee: unrecognised extractor "$id"; treating it as YouTube');
    return YatteeSite.youtube;
  }

  /// The canonical channel URL for [handle] on this site.
  ///
  /// `POST /feed` requires `channel_url` for every non-YouTube channel —
  /// `feed_fetcher.py` can synthesise YouTube's from a `UC…` id but has no
  /// convention for anything else, and raises without it.
  ///
  /// Accepts what a person would actually type on a remote: a bare channel
  /// name, an `@handle`, or a full URL pasted from a browser. Returns null
  /// when nothing usable is left, so callers can reject empty input.
  static String? channelUrlFor(YatteeSite site, String handle) {
    final trimmed = handle.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final parsed = Uri.tryParse(trimmed);
      return parsed != null && parsed.host.isNotEmpty ? trimmed : null;
    }
    final name = trimmed.startsWith('@') ? trimmed.substring(1) : trimmed;
    if (name.isEmpty || name.contains('/')) return null;
    return switch (site) {
      YatteeSite.youtube => 'https://www.youtube.com/@$name',
      YatteeSite.twitch => 'https://www.twitch.tv/$name',
    };
  }
}
