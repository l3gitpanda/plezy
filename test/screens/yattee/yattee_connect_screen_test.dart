import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/yattee/yattee_session.dart';
import 'package:plezy/providers/yattee/yattee_account_provider.dart';
import 'package:plezy/screens/yattee/yattee_connect_screen.dart';
import 'package:plezy/services/yattee/yattee_auth_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

/// Records what the connect flow produced instead of persisting it: the real
/// store writes through the credential vault.
class _RecordingAccount extends YatteeAccountProvider {
  _RecordingAccount(YatteeAuthService authService) : super(authService: authService);

  YatteeSession? adopted;

  @override
  Future<void> adoptSession(YatteeSession session) async => adopted = session;
}

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A Yattee Server that answers only on plain HTTP at its Docker port and
/// accepts exactly one credential pair.
YatteeAuthService _lanInstance() => YatteeAuthService(
  httpClientFactory: () => MockClient((request) async {
    if (request.url.scheme != 'http' || request.url.port != 8085) {
      throw http.ClientException('connection refused', request.url);
    }
    switch (request.url.path) {
      case '/health':
        return _json({'status': 'ok'});
      case '/info':
        if (request.headers['Authorization'] != 'Basic YWxpY2U6aHVudGVyMg==') {
          return _json({'detail': 'Invalid credentials'}, status: 401);
        }
        return _json({'name': 'Yattee Server', 'version': '1.0.9'});
    }
    throw http.ClientException('unexpected ${request.url.path}', request.url);
  }),
);

void main() {
  late _RecordingAccount account;

  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  tearDown(() => account.dispose());

  Widget app(YatteeAuthService auth) {
    account = _RecordingAccount(auth);
    return ChangeNotifierProvider<YatteeAccountProvider>.value(
      value: account,
      child: MaterialApp(theme: monoTheme(dark: true), home: const YatteeConnectScreen()),
    );
  }

  Future<void> submitUrl(WidgetTester tester, String input) async {
    await tester.enterText(find.byType(TextField).first, input);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
  }

  testWidgets('finds a plain-HTTP LAN instance from schemeless input and signs in', (tester) async {
    await tester.pumpWidget(app(_lanInstance()));
    await submitUrl(tester, 'yattee.lan');

    expect(find.text('http://yattee.lan:8085'), findsOneWidget);
    expect(find.text(t.addServer.username), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'alice');
    await tester.enterText(find.byType(TextField).at(1), 'hunter2');
    await tester.tap(find.text(t.addServer.signIn));
    await tester.pumpAndSettle();

    final adopted = account.adopted;
    expect(adopted, isNotNull);
    expect(adopted!.baseUrl, 'http://yattee.lan:8085');
    expect(adopted.username, 'alice');
    expect(adopted.secret, 'hunter2');
    expect(adopted.instanceLabel, 'Yattee Server');
  });

  testWidgets('shows the credential error inline and keeps the form', (tester) async {
    await tester.pumpWidget(app(_lanInstance()));
    await submitUrl(tester, 'http://yattee.lan:8085');

    await tester.enterText(find.byType(TextField).at(0), 'alice');
    await tester.enterText(find.byType(TextField).at(1), 'wrong');
    await tester.tap(find.text(t.addServer.signIn));
    await tester.pumpAndSettle();

    expect(find.text(t.addServer.invalidCredentials), findsOneWidget);
    expect(account.adopted, isNull);
    expect(find.text(t.addServer.username), findsOneWidget);
  });

  testWidgets('reports an unreachable address on the URL step', (tester) async {
    await tester.pumpWidget(app(_lanInstance()));
    await submitUrl(tester, 'https://nowhere.example');

    expect(find.textContaining('nowhere.example'), findsWidgets);
    expect(find.text(t.addServer.username), findsNothing);
  });
}
