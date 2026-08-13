import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/seerr/seerr_session.dart';
import 'package:plezy/providers/seerr_account_provider.dart';
import 'package:plezy/screens/settings/seerr_connect_screen.dart';
import 'package:plezy/services/seerr/seerr_auth_service.dart';
import 'package:plezy/services/seerr/seerr_constants.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

typedef _RequestHandler = Future<http.Response> Function(http.Request request);

http.Response _json(Object body, {int status = 200, Map<String, String>? headers}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...?headers},
);

Map<String, Object?> _publicSettings({
  required bool mediaServerLogin,
  required int mediaServerType,
  bool localLogin = false,
}) => {
  'initialized': true,
  'applicationTitle': 'Test Seerr',
  'localLogin': localLogin,
  'mediaServerLogin': mediaServerLogin,
  'mediaServerType': mediaServerType,
};

Map<String, Object?> _user() => {
  'id': 7,
  'displayName': 'Alice',
  'permissions': 2,
  'avatar': '/avatar.png',
};

class _RecordingSeerrAccountProvider extends SeerrAccountProvider {
  _RecordingSeerrAccountProvider({required super.authService});

  SeerrSession? adoptedSession;

  @override
  Future<void> adoptSession(SeerrSession session) async {
    adoptedSession = session;
  }
}

_RecordingSeerrAccountProvider _provider(_RequestHandler handler) {
  return _RecordingSeerrAccountProvider(
    authService: SeerrAuthService(
      httpClientFactory: () => MockClient(handler),
    ),
  );
}

Widget _app(_RecordingSeerrAccountProvider provider, Widget home) {
  return TranslationProvider(
    child: ChangeNotifierProvider<SeerrAccountProvider>.value(
      value: provider,
      child: InputModeTracker(
        child: MaterialApp(theme: monoTheme(dark: true), home: home),
      ),
    ),
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _RecordingSeerrAccountProvider provider,
) async {
  await tester.pumpWidget(_app(provider, const SeerrConnectScreen()));
  await tester.pump();
}

Future<void> _probe(WidgetTester tester) async {
  await tester.enterText(
    find.byType(TextField).first,
    'https://seerr.example.com',
  );
  await tester.tap(find.text(t.seerr.checkServer));
  // The probe response is immediate, but crosses the HTTP and runAsync
  // futures before scheduling the credential-form frame.
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Seerr Jellyfin Quick Connect availability', () {
    for (final scenario
        in <
          ({
            String name,
            bool mediaServerLogin,
            int mediaServerType,
            bool localLogin,
            bool expected,
          })
        >[
          (
            name: 'is shown for a Jellyfin instance with media sign-in enabled',
            mediaServerLogin: true,
            mediaServerType: SeerrMediaServerType.jellyfin,
            localLogin: false,
            expected: true,
          ),
          (
            name: 'is hidden for an Emby instance',
            mediaServerLogin: true,
            mediaServerType: SeerrMediaServerType.emby,
            localLogin: false,
            expected: false,
          ),
          (
            name: 'is hidden when media-server sign-in is disabled',
            mediaServerLogin: false,
            mediaServerType: SeerrMediaServerType.jellyfin,
            localLogin: true,
            expected: false,
          ),
        ]) {
      testWidgets(scenario.name, (tester) async {
        final provider = _provider((request) async {
          expect(request.url.path, '/api/v1/settings/public');
          return _json(
            _publicSettings(
              mediaServerLogin: scenario.mediaServerLogin,
              mediaServerType: scenario.mediaServerType,
              localLogin: scenario.localLogin,
            ),
          );
        });
        addTearDown(provider.dispose);

        await _pumpScreen(tester, provider);
        await _probe(tester);

        expect(
          find.text(t.auth.useQuickConnect),
          scenario.expected ? findsOneWidget : findsNothing,
        );
      });
    }
  });

  testWidgets('shows the returned code and cancel restores credentials', (
    tester,
  ) async {
    final checkStarted = Completer<void>();
    final checkResponse = Completer<http.Response>();
    var authenticateCalls = 0;
    final provider = _provider((request) async {
      switch (request.url.path) {
        case '/api/v1/settings/public':
          return _json(
            _publicSettings(
              mediaServerLogin: true,
              mediaServerType: SeerrMediaServerType.jellyfin,
            ),
          );
        case '/api/v1/auth/jellyfin/quickconnect/initiate':
          return _json({'code': '654321', 'secret': 'abcdef123456'});
        case '/api/v1/auth/jellyfin/quickconnect/check':
          if (!checkStarted.isCompleted) checkStarted.complete();
          return checkResponse.future;
        case '/api/v1/auth/jellyfin/quickconnect/authenticate':
          authenticateCalls++;
          return _json(_user());
        default:
          fail('Unexpected request: ${request.method} ${request.url}');
      }
    });
    addTearDown(provider.dispose);

    await _pumpScreen(tester, provider);
    await _probe(tester);
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.tap(find.text(t.auth.useQuickConnect));
    await tester.pump();
    await tester.pump();

    expect(find.text('654321'), findsOneWidget);
    expect(find.text(t.auth.quickConnectWaiting), findsOneWidget);
    expect(checkStarted.isCompleted, isTrue);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text(t.auth.quickConnectCancel));
    await tester.pump();

    expect(find.text('654321'), findsNothing);
    expect(find.text(t.auth.useQuickConnect), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    // Release the in-flight check after cancellation. Even an approval must
    // not proceed to the final exchange once the attempt is stale.
    checkResponse.complete(_json({'authenticated': true}));
    await tester.pump();
    await tester.pump();
    expect(authenticateCalls, 0);
  });

  testWidgets('an initiation 404 keeps credential login and shows an error', (
    tester,
  ) async {
    final provider = _provider((request) async {
      switch (request.url.path) {
        case '/api/v1/settings/public':
          return _json(
            _publicSettings(
              mediaServerLogin: true,
              mediaServerType: SeerrMediaServerType.jellyfin,
            ),
          );
        case '/api/v1/auth/jellyfin/quickconnect/initiate':
          return _json({'message': 'Not Found'}, status: 404);
        default:
          fail('Unexpected request: ${request.method} ${request.url}');
      }
    });
    addTearDown(provider.dispose);

    await _pumpScreen(tester, provider);
    await _probe(tester);
    await tester.tap(find.text(t.auth.useQuickConnect));
    await tester.pump();
    await tester.pump();

    expect(find.text(t.auth.useQuickConnect), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text(t.addServer.quickConnectRejected), findsOneWidget);
  });

  testWidgets('an approved flow adopts the cookie-backed Seerr session', (
    tester,
  ) async {
    final checkStarted = Completer<void>();
    final checkResponse = Completer<http.Response>();
    final provider = _provider((request) async {
      switch (request.url.path) {
        case '/api/v1/settings/public':
          return _json(
            _publicSettings(
              mediaServerLogin: true,
              mediaServerType: SeerrMediaServerType.jellyfin,
            ),
          );
        case '/api/v1/auth/jellyfin/quickconnect/initiate':
          return _json({'code': '123456', 'secret': 'abcdef123456'});
        case '/api/v1/auth/jellyfin/quickconnect/check':
          if (!checkStarted.isCompleted) checkStarted.complete();
          return checkResponse.future;
        case '/api/v1/auth/jellyfin/quickconnect/authenticate':
          expect(jsonDecode(request.body), {'secret': 'abcdef123456'});
          return _json(
            _user(),
            headers: {
              'set-cookie': '${SeerrConstants.sessionCookieName}=fresh-qc; Path=/; HttpOnly',
            },
          );
        default:
          fail('Unexpected request: ${request.method} ${request.url}');
      }
    });
    addTearDown(provider.dispose);

    late Future<bool?> routeResult;
    await tester.pumpWidget(
      _app(
        provider,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  routeResult = Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) => const SeerrConnectScreen(),
                    ),
                  );
                },
                child: const Text('Open Seerr connect'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Seerr connect'));
    await tester.pumpAndSettle();
    await _probe(tester);
    await tester.tap(find.text(t.auth.useQuickConnect));
    await tester.pump();
    await tester.pump();
    expect(checkStarted.isCompleted, isTrue);

    checkResponse.complete(_json({'authenticated': true}));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(await routeResult, isTrue);
    expect(provider.adoptedSession, isNotNull);
    expect(provider.adoptedSession!.method, SeerrAuthMethod.jellyfin);
    expect(provider.adoptedSession!.cookie, 'fresh-qc');
    expect(provider.adoptedSession!.identifier, isEmpty);
    expect(provider.adoptedSession!.secret, isEmpty);
    expect(provider.adoptedSession!.instanceLabel, 'Test Seerr');
  });
}
