import 'dart:async';

import 'package:http/http.dart' as http;

import '../../i18n/strings.g.dart';
import '../../models/yattee/yattee_session.dart';
import '../../models/yattee/yattee_video.dart';
import '../../utils/app_logger.dart';
import '../../utils/url_utils.dart';
import 'yattee_constants.dart';
import 'yattee_exceptions.dart';
import 'yattee_http_client.dart';

/// Connect-flow half of the Yattee integration: URL discovery and the
/// credential check. Sessions never expire server-side (Basic Auth is
/// stateless), so there is no re-auth path — a rejected credential surfaces
/// as [YatteeAuthException] at the call site.
class YatteeAuthService {
  /// Test seam: supplies the underlying `http.Client`. Null in production.
  final http.Client Function()? httpClientFactory;

  YatteeAuthService({this.httpClientFactory});

  /// Schemeless-input guesses, TLS first, then the two default install ports
  /// over plain HTTP — a LAN instance is usually one of those.
  static final List<BaseUrlGuess> _schemelessGuesses = [
    (scheme: 'https', port: null),
    (scheme: 'http', port: null),
    for (final port in YatteeConstants.defaultPorts) (scheme: 'http', port: port),
  ];

  static List<String> expandUrlCandidates(String input) => expandBaseUrlCandidates(input, guesses: _schemelessGuesses);

  /// `GET /health` (auth-exempt) must answer `{"status":"ok"}`. Any other 2xx
  /// body is some other web server on that address.
  Future<void> probe(String baseUrl) async {
    final client = YatteeHttpClient(baseUrl: baseUrl, httpClient: httpClientFactory?.call());
    try {
      final data = await client.send('GET', '/health', timeout: YatteeConstants.probeTimeout);
      if (data is! Map || data['status'] != 'ok') {
        throw YatteeUrlException(
          'No Yattee Server at $baseUrl',
          display: t.yattee.noInstanceAtUrl(url: baseUrl),
          statusCode: 200,
        );
      }
    } on YatteeUrlException {
      rethrow;
    } on YatteeApiException catch (e) {
      throw YatteeUrlException(
        'No Yattee Server at $baseUrl (HTTP ${e.statusCode})',
        display: t.yattee.noInstanceAtUrl(url: baseUrl),
        statusCode: e.statusCode,
      );
    } on YatteeAuthException catch (e) {
      // /health is exempt from Basic Auth, so a 401 here is a login wall in
      // front of the server, not Yattee itself.
      throw YatteeUrlException(
        'Auth wall in front of $baseUrl (HTTP ${e.statusCode})',
        display: t.yattee.behindAuthProxy,
        statusCode: e.statusCode,
      );
    } catch (e) {
      throw YatteeUrlException(
        'Could not reach $baseUrl: $e',
        display: t.yattee.couldNotReach(url: baseUrl, error: e.toString()),
      );
    } finally {
      client.dispose();
    }
  }

  /// Probes every [expandUrlCandidates] guess for [input] and returns the
  /// first reachable base URL.
  ///
  /// TLS wins by construction: probes all start together, but a plaintext
  /// success is held while any `https` candidate is still in flight and is
  /// only accepted once they have all failed — the sign-in that follows
  /// sends a password to whichever URL wins here.
  Future<String> probeFirstReachable(String input) async {
    final candidates = expandUrlCandidates(input);
    if (candidates.isEmpty) {
      throw YatteeUrlException('Not a usable Yattee Server URL: "$input"', display: t.yattee.invalidUrl);
    }
    if (candidates.length == 1) {
      await probe(candidates.single);
      return candidates.single;
    }

    final completer = Completer<String>();
    final failures = List<(Object, StackTrace)?>.filled(candidates.length, null);
    var pending = candidates.length;
    var pendingSecure = candidates.where(_isSecure).length;
    String? heldPlaintext;

    void settle() {
      if (completer.isCompleted) return;
      final held = heldPlaintext;
      if (held != null && pendingSecure == 0) {
        appLogger.d('Yattee: no TLS candidate answered, accepting the plaintext instance URL');
        completer.complete(held);
        return;
      }
      if (pending == 0) {
        final (error, stackTrace) = _mostInformativeFailure(failures);
        completer.completeError(error, stackTrace);
      }
    }

    for (final (index, candidate) in candidates.indexed) {
      final secure = _isSecure(candidate);
      unawaited(
        probe(candidate).then(
          (_) {
            pending -= 1;
            if (secure) pendingSecure -= 1;
            if (completer.isCompleted) return;
            if (secure) {
              completer.complete(candidate);
              return;
            }
            heldPlaintext ??= candidate;
            settle();
          },
          onError: (Object error, StackTrace stackTrace) {
            failures[index] = (error, stackTrace);
            pending -= 1;
            if (secure) pendingSecure -= 1;
            settle();
          },
        ),
      );
    }
    return completer.future;
  }

  static bool _isSecure(String baseUrl) => baseUrl.startsWith('https://');

  /// The failure worth showing: one that came back from a server outranks a
  /// transport error, and the first candidate — the URL the user most likely
  /// meant — outranks later guesses.
  static (Object, StackTrace) _mostInformativeFailure(List<(Object, StackTrace)?> failures) {
    for (final failure in failures) {
      if (failure case (final YatteeUrlException e, _) when e.statusCode != null) return failure;
    }
    return failures.firstWhere((failure) => failure != null)!;
  }

  /// Verify [username]/[password] against `/info`, which answers the full
  /// body only to an authenticated request and `401` otherwise. The `name`
  /// it returns doubles as the instance check: an Invidious instance at the
  /// same address has no `/info` at all.
  Future<YatteeSession> signIn({required String baseUrl, required String username, required String password}) async {
    final client = YatteeHttpClient(
      baseUrl: baseUrl,
      username: username,
      password: password,
      httpClient: httpClientFactory?.call(),
    );
    try {
      final data = await client.send('GET', '/info', timeout: YatteeConstants.probeTimeout);
      if (data is! Map<String, dynamic>) {
        throw YatteeUrlException(
          'Unexpected /info body from $baseUrl',
          display: t.yattee.noInstanceAtUrl(url: baseUrl),
        );
      }
      final info = YatteeServerInfo.fromJson(data);
      if (!info.isYatteeServer) {
        throw YatteeUrlException(
          'Server at $baseUrl is not a Yattee Server (name: ${info.name})',
          display: t.yattee.noInstanceAtUrl(url: baseUrl),
          statusCode: 200,
        );
      }
      return YatteeSession(
        baseUrl: client.baseUrl,
        username: username,
        secret: password,
        instanceLabel: info.name,
        version: info.version,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
    } on YatteeAuthException catch (e) {
      throw YatteeAuthException(
        e.message,
        statusCode: e.statusCode,
        display: e.statusCode == 429 ? t.yattee.tooManyAttempts : t.addServer.invalidCredentials,
      );
    } finally {
      client.dispose();
    }
  }
}
