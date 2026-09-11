/// Constants for the Yattee Server (yattee/yattee-server) REST API — a
/// yt-dlp-backed service that speaks Invidious's JSON shapes.
abstract final class YatteeConstants {
  /// Every catalog endpoint lives under this prefix on the instance base URL.
  static const String apiPath = '/api/v1';

  /// Default ports of a Yattee Server install: 8085 for the published Docker
  /// image, 8080 when run from source. Tried for schemeless input that names
  /// no port of its own.
  static const List<int> defaultPorts = [8085, 8080];

  /// Every subscription channel is `site: youtube`; the server also proxies
  /// other yt-dlp extractors, but Plezy only browses YouTube.
  static const String site = 'youtube';

  /// `POST /feed` rejects more channels than this per call (422).
  static const int feedChannelLimit = 500;

  static const Duration probeTimeout = Duration(seconds: 8);
  static const Duration requestTimeout = Duration(seconds: 30);

  /// `/videos/{id}` runs yt-dlp on a cache miss, which can take a while on a
  /// small server.
  static const Duration videoTimeout = Duration(seconds: 90);
}
