import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../utils/abortable_http_request.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_http_client_stub.dart'
    if (dart.library.io) '../../utils/platform_http_client_io.dart'
    as platform;
import '../../utils/url_utils.dart';
import '../trackers/tracker_http_client.dart';
import 'yattee_constants.dart';
import 'yattee_exceptions.dart';

/// Thin wrapper around `package:http` for Yattee Server calls.
///
/// The server enforces HTTP Basic Auth on every `/api/v1` route once an
/// account exists, so the `Authorization` header is baked in per instance.
/// Media routes (`/proxy/*`, thumbnails, captions) are exempt and carry a
/// server-minted `token`/`sig` query parameter instead; the URLs the API
/// returns are used verbatim and never go through this client.
class YatteeHttpClient {
  final String baseUrl;
  final String? _authorization;
  final http.Client _http;

  YatteeHttpClient({required String baseUrl, String? username, String? password, http.Client? httpClient})
    : baseUrl = canonicalizeBaseUrl(baseUrl),
      _authorization = basicAuthorization(username, password),
      _http = httpClient ?? platform.createPlatformClient();

  /// `Basic base64(user:pass)`, or null when no username is configured.
  static String? basicAuthorization(String? username, String? password) {
    if (username == null || username.isEmpty) return null;
    return 'Basic ${base64Encode(utf8.encode('$username:${password ?? ''}'))}';
  }

  void dispose() => _http.close();

  /// GET/POST [path] (absolute on the instance — callers prefix
  /// [YatteeConstants.apiPath] themselves so `/health` and `/info` share the
  /// code) and decode the JSON body. 401/403 and 429 raise
  /// [YatteeAuthException]; any other non-2xx raises [YatteeApiException].
  Future<dynamic> send(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? body,
    Duration timeout = YatteeConstants.requestTimeout,
  }) async {
    final uri = _uri(path, query);
    final headers = <String, String>{
      'Accept': 'application/json',
      if (_authorization != null) 'Authorization': _authorization,
      if (body != null) 'Content-Type': 'application/json',
    };
    final sw = Stopwatch()..start();
    // Abortable so a timeout releases transport resources. Redirects are not
    // followed: the API never issues one, so a 3xx is a login wall in front
    // of the server, and following it would turn that into an HTML 200
    // nobody can diagnose.
    final response = await sendAbortableHttpRequest(
      _http,
      method,
      uri,
      headers: headers,
      body: body == null ? null : jsonEncode(body),
      timeout: timeout,
      operation: 'Yattee $method $path',
      followRedirects: false,
    );
    appLogger.d('Yattee $method $path -> ${response.statusCode} (${sw.elapsedMilliseconds}ms)');
    final data = TrackerHttpClient.decodeJson(response.body);
    final code = response.statusCode;
    if (code >= 200 && code < 300) return data;
    final detail = data is Map ? data['detail'] : null;
    final message = detail is String && detail.isNotEmpty ? detail : 'HTTP $code';
    if (code == 401 || code == 403 || code == 429) {
      throw YatteeAuthException(message, statusCode: code);
    }
    throw YatteeApiException(message, statusCode: code);
  }

  Uri _uri(String path, Map<String, Object?>? query) {
    final base = Uri.parse('$baseUrl$path');
    final encoded = encodeQueryParameters(query);
    return encoded.isEmpty ? base : base.replace(query: encoded);
  }
}
