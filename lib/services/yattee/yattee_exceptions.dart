/// The URL doesn't point at a reachable Yattee Server.
///
/// [message] is English for stable logs and Sentry grouping. [display] is the
/// localized user-facing text when this failure is rendered in the UI.
class YatteeUrlException implements Exception {
  final String message;
  final String? display;

  /// Status of the response that disqualified the URL, when one arrived at
  /// all. Null means nothing answered (DNS, refused, TLS, timeout), which is
  /// how candidate racing tells "reached a server that isn't Yattee" apart
  /// from "never reached anything".
  final int? statusCode;
  const YatteeUrlException(this.message, {this.display, this.statusCode});

  @override
  String toString() => 'YatteeUrlException: $message';
}

/// The server rejected the Basic Auth credentials (401/403), or throttled
/// repeated failures (429).
class YatteeAuthException implements Exception {
  final String message;
  final String? display;
  final int? statusCode;
  const YatteeAuthException(this.message, {this.statusCode, this.display});

  @override
  String toString() => 'YatteeAuthException: $message${statusCode == null ? '' : ' ($statusCode)'}';
}

/// Any other non-2xx answer, carrying FastAPI's `detail` when it sent one.
class YatteeApiException implements Exception {
  final String message;
  final int statusCode;
  const YatteeApiException(this.message, {required this.statusCode});

  @override
  String toString() => 'YatteeApiException($statusCode): $message';
}
