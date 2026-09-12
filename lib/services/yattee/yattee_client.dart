import 'package:http/http.dart' as http;

import '../../models/yattee/yattee_session.dart';
import '../../models/yattee/yattee_video.dart';
import 'yattee_constants.dart';
import 'yattee_exceptions.dart';
import 'yattee_http_client.dart';

/// Search hit types `/search` can be asked for.
enum YatteeSearchType { video, channel, all }

/// Catalog and playback calls against one connected Yattee Server.
///
/// Every method maps the server's Invidious-shaped JSON onto the DTOs in
/// `models/yattee`; nothing here touches playback or persistence.
class YatteeClient {
  final YatteeSession session;
  final YatteeHttpClient _http;

  YatteeClient(this.session, {http.Client? httpClient})
    : _http = YatteeHttpClient(
        baseUrl: session.baseUrl,
        username: session.username,
        password: session.secret,
        httpClient: httpClient,
      );

  String get baseUrl => _http.baseUrl;

  void dispose() => _http.dispose();

  static const String _api = YatteeConstants.apiPath;

  Future<YatteeServerInfo> fetchInfo() async {
    final data = await _http.send('GET', '/info', timeout: YatteeConstants.probeTimeout);
    return YatteeServerInfo.fromJson(_asMap(data, '/info'));
  }

  /// `GET /trending`. [region] is an ISO 3166-1 country code; the server
  /// defaults to US when omitted.
  Future<List<YatteeVideoSummary>> fetchTrending({String? region}) async {
    final data = await _http.send('GET', '$_api/trending', query: {'region': ?region});
    return YatteeVideoSummary.listFromJson(data);
  }

  Future<List<YatteeVideoSummary>> fetchPopular() async {
    final data = await _http.send('GET', '$_api/popular');
    return YatteeVideoSummary.listFromJson(data);
  }

  /// `POST /feed` with the client-held subscription list. The server caps
  /// one call at [YatteeConstants.feedChannelLimit] channels; larger lists
  /// are sent in chunks and the pages merged, newest first.
  Future<YatteeFeedPage> fetchFeed(List<YatteeSubscription> subscriptions, {int limit = 50, int offset = 0}) async {
    if (subscriptions.isEmpty) {
      return const YatteeFeedPage(status: 'ready', videos: [], total: 0, hasMore: false);
    }
    final pages = <YatteeFeedPage>[];
    for (var start = 0; start < subscriptions.length; start += YatteeConstants.feedChannelLimit) {
      final chunk = subscriptions.sublist(
        start,
        (start + YatteeConstants.feedChannelLimit).clamp(0, subscriptions.length),
      );
      final data = await _http.send(
        'POST',
        '$_api/feed',
        body: {
          'channels': [
            for (final subscription in chunk)
              {
                'channel_id': subscription.channelId,
                'site': YatteeConstants.site,
                'channel_name': subscription.name,
                if (subscription.avatarUrl != null) 'avatar_url': subscription.avatarUrl,
              },
          ],
          'limit': limit,
          'offset': offset,
        },
      );
      pages.add(YatteeFeedPage.fromJson(_asMap(data, '/feed')));
    }
    if (pages.length == 1) return pages.single;
    final videos = [for (final page in pages) ...page.videos]
      ..sort((a, b) => (b.published ?? 0).compareTo(a.published ?? 0));
    return YatteeFeedPage(
      status: pages.any((page) => page.status == 'fetching') ? 'fetching' : 'ready',
      videos: videos.take(limit).toList(),
      total: pages.fold(0, (sum, page) => sum + page.total),
      hasMore: pages.any((page) => page.hasMore) || videos.length > limit,
      readyCount: pages.fold(0, (sum, page) => sum + page.readyCount),
      pendingCount: pages.fold(0, (sum, page) => sum + page.pendingCount),
      errorCount: pages.fold(0, (sum, page) => sum + page.errorCount),
      etaSeconds: pages
          .map((page) => page.etaSeconds)
          .whereType<int>()
          .fold<int?>(null, (a, b) => a == null ? b : (a > b ? a : b)),
    );
  }

  /// Channels this server has been asked to watch, as a one-time seed for
  /// the client-held subscription list.
  ///
  /// Yattee Server has no per-user subscription list: `watched_channels` is
  /// keyed on `(channel_id, site)` with no user column, and `POST /feed` only
  /// upserts whatever channels the caller sent. But every Yattee client posts
  /// its *whole* subscription list on each feed refresh, so on a single-user
  /// instance this set is that user's subscriptions.
  ///
  /// Three things make it a seed rather than a sync source, and callers must
  /// treat it that way — merge, never replace:
  ///   * it is global, so a multi-user server returns everyone's channels;
  ///   * the server deletes rows untouched for 14 days;
  ///   * it is admin-only, and a non-admin account simply gets nothing.
  ///
  /// Lives at the root, not under [YatteeConstants.apiPath] — the admin
  /// router is mounted without the `/api/v1` prefix.
  ///
  /// Throws rather than swallowing: 403 ("Admin privileges required") and 404
  /// (a server predating the route) mean very different things to the user,
  /// so the caller classifies them instead of seeing one empty list.
  Future<List<YatteeSubscription>> fetchWatchedChannels() async {
    final data = await _http.send('GET', '/api/watched-channels');
    if (data is! List) return const [];
    final subscriptions = <YatteeSubscription>[];
    for (final entry in data) {
      if (entry is! Map) continue;
      final row = entry.cast<String, Object?>();
      if (row['site'] != YatteeConstants.site) continue;
      final channelId = row['channel_id']?.toString();
      if (channelId == null || channelId.isEmpty) continue;
      final name = row['channel_name']?.toString();
      final avatarUrl = row['avatar_url']?.toString();
      subscriptions.add(
        YatteeSubscription(
          channelId: channelId,
          name: name == null || name.isEmpty ? channelId : name,
          avatarUrl: avatarUrl == null || avatarUrl.isEmpty ? null : avatarUrl,
        ),
      );
    }
    return subscriptions;
  }

  Future<YatteeSearchResults> search(String query, {int page = 1, YatteeSearchType type = YatteeSearchType.all}) async {
    final data = await _http.send('GET', '$_api/search', query: {'q': query, 'page': page, 'type': type.name});
    return YatteeSearchResults.fromJson(data);
  }

  /// `GET /search/suggestions`: a bare JSON array of strings.
  Future<List<String>> searchSuggestions(String query) async {
    final data = await _http.send(
      'GET',
      '$_api/search/suggestions',
      query: {'q': query},
      timeout: YatteeConstants.probeTimeout,
    );
    if (data is! List) return const [];
    return [
      for (final entry in data)
        if (entry is String && entry.isNotEmpty) entry,
    ];
  }

  /// `GET /channels/{id}` — accepts a `UC…` id or an `@handle`.
  Future<YatteeChannel> fetchChannel(String channelId) async {
    final data = await _http.send('GET', '$_api/channels/${Uri.encodeComponent(channelId)}');
    return YatteeChannel.fromJson(_asMap(data, '/channels'));
  }

  Future<YatteeChannelVideosPage> fetchChannelVideos(String channelId, {String? continuation}) async {
    final data = await _http.send(
      'GET',
      '$_api/channels/${Uri.encodeComponent(channelId)}/videos',
      query: {'continuation': ?continuation},
    );
    return YatteeChannelVideosPage.fromJson(_asMap(data, '/channels/videos'));
  }

  /// `GET /videos/{id}`. Always asks the server to relay the streams:
  /// unproxied googlevideo URLs are bound to the IP that resolved them —
  /// the server's, not this device's — and fail from anywhere else.
  Future<YatteeVideo> fetchVideo(String videoId) async {
    final data = await _http.send(
      'GET',
      '$_api/videos/${Uri.encodeComponent(videoId)}',
      query: const {'proxy': 'true', 'proxy_mode': 'relay'},
      timeout: YatteeConstants.videoTimeout,
    );
    return YatteeVideo.fromJson(_asMap(data, '/videos'));
  }

  static Map<String, dynamic> _asMap(dynamic data, String path) {
    if (data is Map<String, dynamic>) return data;
    throw YatteeApiException('Unexpected response shape from $path', statusCode: 200);
  }
}
