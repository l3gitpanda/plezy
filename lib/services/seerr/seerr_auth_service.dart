import 'package:http/http.dart' as http;

import '../../i18n/strings.g.dart';
import '../../models/seerr/seerr_public_settings.dart';
import '../../models/seerr/seerr_session.dart';
import '../../models/seerr/seerr_user.dart';
import '../../utils/app_logger.dart';
import '../../utils/log_redaction_manager.dart';
import '../../utils/poll_with_backoff.dart';
import 'seerr_constants.dart';
import 'seerr_exceptions.dart';
import 'seerr_http_client.dart';

/// User-facing code and polling secret returned when Seerr starts a Jellyfin
/// Quick Connect session.
class SeerrQuickConnectInitiation {
  final String code;
  final String secret;

  const SeerrQuickConnectInitiation({required this.code, required this.secret});
}

/// Sign-in flows against a Seerr instance. Every flow ends with a captured
/// `connect.sid` cookie and the Seerr-side [SeerrUser], packed into a
/// [SeerrSession].
class SeerrAuthService {
  final http.Client Function()? httpClientFactory;

  SeerrAuthService({this.httpClientFactory});

  SeerrHttpClient _client(String baseUrl, {String? cookie}) =>
      SeerrHttpClient(baseUrl: baseUrl, httpClient: httpClientFactory?.call(), cookie: cookie);

  /// Validate that [baseUrl] points at a running, initialized Seerr and
  /// collect the metadata the connect flow needs. Throws [SeerrUrlException]
  /// when unreachable or not set up.
  Future<SeerrPublicSettings> probe(String baseUrl) async {
    final client = _client(baseUrl);
    try {
      final SeerrResponse res;
      try {
        res = await client.send('GET', '/settings/public', timeout: SeerrConstants.probeTimeout, authenticated: false);
      } catch (e) {
        throw SeerrUrlException(
          'Could not reach $baseUrl: $e',
          display: t.seerr.couldNotReach(url: baseUrl, error: e),
        );
      }
      final data = res.data;
      if (res.statusCode >= 400 || data is! Map<String, dynamic>) {
        throw SeerrUrlException(
          'No Seerr instance at $baseUrl (HTTP ${res.statusCode})',
          display: t.seerr.noInstanceAtUrl(url: baseUrl, status: res.statusCode),
        );
      }
      final settings = SeerrPublicSettings.fromJson(data);
      if (!settings.initialized) {
        throw SeerrUrlException('Seerr instance has not completed first-run setup', display: t.seerr.notInitialized);
      }
      return settings;
    } finally {
      client.dispose();
    }
  }

  /// `POST /auth/plex` with a Plex account token.
  Future<SeerrSession> signInWithPlex({required String baseUrl, required String plexToken}) => _signIn(
    baseUrl: baseUrl,
    method: SeerrAuthMethod.plex,
    path: '/auth/plex',
    body: {'authToken': plexToken},
    identifier: '',
    secret: '',
  );

  /// `POST /auth/jellyfin` with Jellyfin or Emby credentials.
  Future<SeerrSession> signInWithJellyfin({
    required String baseUrl,
    required String username,
    required String password,
    bool emby = false,
  }) => _signIn(
    baseUrl: baseUrl,
    method: emby ? SeerrAuthMethod.emby : SeerrAuthMethod.jellyfin,
    path: '/auth/jellyfin',
    body: {
      'username': username,
      'password': password,
      'serverType': emby ? SeerrMediaServerType.emby : SeerrMediaServerType.jellyfin,
    },
    identifier: username,
    secret: password,
  );

  /// Starts Jellyfin Quick Connect through Seerr and returns the code the user
  /// must approve in Jellyfin together with the secret used for polling.
  Future<SeerrQuickConnectInitiation> initiateJellyfinQuickConnect({required String baseUrl}) async {
    final client = _client(baseUrl);
    try {
      final res = await client.send(
        'POST',
        '/auth/jellyfin/quickconnect/initiate',
        timeout: SeerrConstants.authTimeout,
        authenticated: false,
      );
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw SeerrAuthException(
          'Quick Connect initiation rejected by Seerr',
          statusCode: res.statusCode,
          display: t.addServer.quickConnectRejected,
        );
      }
      SeerrHttpClient.throwForStatus(res);
      final data = res.data;
      if (data is! Map<String, dynamic>) {
        throw SeerrAuthException(
          'Quick Connect initiation response was not JSON',
          display: t.addServer.quickConnectNotJson,
        );
      }
      final code = data['code'] as String?;
      final secret = data['secret'] as String?;
      if (code == null || code.isEmpty || secret == null || secret.isEmpty) {
        throw SeerrAuthException(
          'Quick Connect initiation response missing code or secret',
          display: t.addServer.quickConnectMissingFields,
        );
      }
      LogRedactionManager.registerCustomValue(secret);
      return SeerrQuickConnectInitiation(code: code, secret: secret);
    } finally {
      client.dispose();
    }
  }

  /// Polls Seerr until the Jellyfin Quick Connect code is approved, then
  /// exchanges the secret for a normal Seerr cookie-backed session. Returns
  /// null when cancelled, timed out, or when Seerr reports an expired secret.
  Future<SeerrSession?> signInWithJellyfinQuickConnect({
    required String baseUrl,
    required String secret,
    Duration timeout = const Duration(minutes: 10),
    bool Function()? shouldCancel,
  }) async {
    LogRedactionManager.registerCustomValue(secret);
    final client = _client(baseUrl);
    try {
      var consecutivePollErrors = 0;
      final approved = await pollWithBackoff<bool>(
        endTime: DateTime.now().add(timeout),
        shouldCancel: shouldCancel,
        initial: const Duration(seconds: 2),
        maxBackoff: const Duration(seconds: 2),
        probe: () async {
          try {
            final res = await client.send(
              'GET',
              '/auth/jellyfin/quickconnect/check',
              query: {'secret': secret},
              timeout: SeerrConstants.authTimeout,
              authenticated: false,
            );
            if (res.statusCode == 404) throw const PollTerminatedSignal();
            if (res.statusCode >= 400 && res.statusCode < 500) {
              throw SeerrAuthException(
                'Quick Connect polling rejected by Seerr',
                statusCode: res.statusCode,
                display: t.addServer.quickConnectPollRejected,
              );
            }
            SeerrHttpClient.throwForStatus(res);
            final data = res.data;
            if (data is! Map<String, dynamic> || data['authenticated'] is! bool) {
              throw SeerrAuthException(
                'Quick Connect polling response was not valid JSON',
                display: t.addServer.quickConnectNotJson,
              );
            }
            consecutivePollErrors = 0;
            return data['authenticated'] == true ? true : null;
          } on PollTerminatedSignal {
            rethrow;
          } catch (_) {
            consecutivePollErrors++;
            if (consecutivePollErrors >= 5) rethrow;
            return null;
          }
        },
      );
      if (approved != true || (shouldCancel?.call() ?? false)) return null;

      final res = await client.send(
        'POST',
        '/auth/jellyfin/quickconnect/authenticate',
        body: {'secret': secret},
        timeout: SeerrConstants.authTimeout,
        authenticated: false,
      );
      if (res.statusCode >= 400 && res.statusCode < 500) {
        throw SeerrAuthException(
          'Quick Connect authentication rejected by Seerr',
          statusCode: res.statusCode,
          display: t.addServer.quickConnectRejected,
        );
      }
      SeerrHttpClient.throwForStatus(res);
      return _sessionFromResponse(
        client: client,
        response: res,
        method: SeerrAuthMethod.jellyfin,
        identifier: '',
        secret: '',
      );
    } finally {
      client.dispose();
    }
  }

  /// `POST /auth/local` with a Seerr local account.
  Future<SeerrSession> signInWithLocal({required String baseUrl, required String email, required String password}) =>
      _signIn(
        baseUrl: baseUrl,
        method: SeerrAuthMethod.local,
        path: '/auth/local',
        body: {'email': email, 'password': password},
        identifier: email,
        secret: password,
      );

  /// Silent re-login using the credentials carried by [session]
  /// ([plexToken] for plex-method sessions). Returns the refreshed session.
  Future<SeerrSession> reauth(SeerrSession session, {String? plexToken}) async {
    final fresh = await switch (session.method) {
      SeerrAuthMethod.plex when plexToken != null && plexToken.isNotEmpty => signInWithPlex(
        baseUrl: session.baseUrl,
        plexToken: plexToken,
      ),
      // No token RIGHT NOW is a degraded state (identity not hydrated yet,
      // vault decrypt hiccup), not a server rejection — retryable, so it
      // must not unlink the session. An empty stored secret below is the
      // opposite: those credentials are gone for good, so re-linking is the
      // only way forward and unlinking is honest.
      SeerrAuthMethod.plex => throw SeerrReauthUnavailableException(
        'No Plex token available for silent re-auth',
        display: t.seerr.noPlexTokenForReauth,
      ),
      SeerrAuthMethod.jellyfin || SeerrAuthMethod.emby when session.secret.isNotEmpty => signInWithJellyfin(
        baseUrl: session.baseUrl,
        username: session.identifier,
        password: session.secret,
        emby: session.method == SeerrAuthMethod.emby,
      ),
      SeerrAuthMethod.local when session.secret.isNotEmpty => signInWithLocal(
        baseUrl: session.baseUrl,
        email: session.identifier,
        password: session.secret,
      ),
      _ => throw SeerrAuthException('No stored credentials for silent re-auth', display: t.seerr.noStoredCredentials),
    };
    return session.copyWith(cookie: fresh.cookie, permissions: fresh.permissions, displayName: fresh.displayName);
  }

  /// Best-effort server-side sign-out; local cleanup must not depend on it.
  Future<void> signOut(SeerrSession session) async {
    final client = _client(session.baseUrl, cookie: session.cookie);
    try {
      await client.send('POST', '/auth/logout', timeout: SeerrConstants.authTimeout);
    } catch (e) {
      appLogger.d('Seerr: sign-out best-effort failed', error: e);
    } finally {
      client.dispose();
    }
  }

  Future<SeerrSession> _signIn({
    required String baseUrl,
    required SeerrAuthMethod method,
    required String path,
    required Map<String, Object?> body,
    required String identifier,
    required String secret,
  }) async {
    final client = _client(baseUrl);
    try {
      final res = await client.send(
        'POST',
        path,
        body: body,
        timeout: SeerrConstants.authTimeout,
        authenticated: false,
      );
      if (res.statusCode == 401 || res.statusCode == 403) {
        final message = res.data is Map<String, dynamic>
            ? (res.data as Map<String, dynamic>)['message'] as String?
            : null;
        throw SeerrAuthException(
          message ?? 'Sign-in rejected',
          statusCode: res.statusCode,
          display: t.seerr.signInRejected,
        );
      }
      SeerrHttpClient.throwForStatus(res);
      return _sessionFromResponse(
        client: client,
        response: res,
        method: method,
        identifier: identifier,
        secret: secret,
      );
    } finally {
      client.dispose();
    }
  }

  Future<SeerrSession> _sessionFromResponse({
    required SeerrHttpClient client,
    required SeerrResponse response,
    required SeerrAuthMethod method,
    required String identifier,
    required String secret,
  }) async {
    if (!client.captureSessionCookie(response.response)) {
      throw SeerrAuthException('Seerr did not issue a session cookie', display: t.seerr.noSessionCookie);
    }
    final user = await _resolveUser(client, response.data);
    return SeerrSession(
      baseUrl: client.baseUrl,
      method: method,
      identifier: identifier,
      secret: secret,
      cookie: client.cookie!,
      userId: user.id,
      permissions: user.permissions ?? 0,
      displayName: user.displayName ?? identifier,
      instanceLabel: '',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// The login endpoints return the [SeerrUser] directly; fall back to
  /// `GET /auth/me` with the fresh cookie if that shape ever changes.
  Future<SeerrUser> _resolveUser(SeerrHttpClient client, dynamic loginData) async {
    if (loginData is Map<String, dynamic>) {
      try {
        return SeerrUser.fromJson(loginData);
      } catch (_) {
        // fall through to /auth/me
      }
    }
    final res = await client.send('GET', '/auth/me', timeout: SeerrConstants.authTimeout);
    // throwForStatus passes 401 through (it's normally the re-auth signal);
    // here it means the fresh cookie was rejected — an auth failure, not a
    // malformed-user-payload crash further down.
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw SeerrAuthException(
        'Seerr rejected the fresh session cookie',
        statusCode: res.statusCode,
        display: t.seerr.freshCookieRejected,
      );
    }
    SeerrHttpClient.throwForStatus(res);
    final data = res.data;
    if (data is Map<String, dynamic>) return SeerrUser.fromJson(data);
    throw SeerrAuthException('Seerr did not return user information', display: t.seerr.noUserInformation);
  }
}
