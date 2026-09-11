import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/yattee/yattee_session.dart';
import 'package:plezy/providers/yattee/yattee_account_provider.dart';
import 'package:plezy/screens/yattee/youtube_screen.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/yattee/yattee_auth_service.dart';
import 'package:plezy/services/yattee/yattee_store.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _video(String id, String title) => {
  'type': 'video',
  'videoId': id,
  'title': title,
  'author': 'Author $id',
  'authorId': 'UC$id',
  'lengthSeconds': 90,
  'published': 1700000000,
  'publishedText': '1 day ago',
  'viewCount': 1200,
  'videoThumbnails': const [],
  'liveNow': false,
  'isUpcoming': false,
};

/// A Yattee Server with one trending, one popular and one feed video. Feed
/// requests are recorded so the subscription list sent can be asserted.
class _FakeServer {
  final feedBodies = <Map<String, dynamic>>[];
  final searchQueries = <String>[];

  http.Client client() => MockClient((request) async {
    expect(request.headers['Authorization'], 'Basic YWxpY2U6aHVudGVyMg==');
    switch (request.url.path) {
      case '/api/v1/trending':
        return _json([_video('trend1', 'Trending One')]);
      case '/api/v1/popular':
        return _json([_video('pop1', 'Popular One')]);
      case '/api/v1/feed':
        feedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _json({
          'status': 'ready',
          'videos': [_video('feed1', 'Feed One')],
          'total': 1,
          'has_more': false,
          'ready_count': 1,
          'pending_count': 0,
          'error_count': 0,
          'eta_seconds': null,
        });
      case '/api/v1/search':
        searchQueries.add(request.url.queryParameters['q']!);
        return _json([
          _video('s1', 'Search Hit'),
          {'type': 'channel', 'authorId': 'UCsearch', 'author': 'Search Channel', 'authorThumbnails': const []},
        ]);
    }
    throw http.ClientException('unexpected ${request.url.path}', request.url);
  });
}

Future<(YatteeAccountProvider, _FakeServer)> _pumpYouTube(WidgetTester tester, {bool subscribed = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final server = _FakeServer();
  final account = YatteeAccountProvider(
    store: const YatteeStore(),
    authService: YatteeAuthService(httpClientFactory: server.client),
  );
  addTearDown(account.dispose);
  // Seeded as a plaintext secret rather than adopted through the provider —
  // the store reads a plain secret back unchanged (the legacy-plaintext
  // path) — and under runAsync: the widget test's fake zone only drives
  // microtasks and pumped timers, which the preference store's writes and
  // the credential vault's key setup are not.
  await tester.runAsync(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(
      'user_user-1_yattee_session',
      YatteeSession(
        baseUrl: 'https://yattee.example.com',
        username: 'alice',
        secret: 'hunter2',
        instanceLabel: 'Yattee Server',
        version: '1.0.9',
        createdAt: 0,
      ).encode(),
    );
    await account.onActiveProfileChanged('user-1');
    if (subscribed) await account.subscribe(const YatteeSubscription(channelId: 'UCfeed', name: 'Feed Channel'));
  });

  await tester.pumpWidget(
    TranslationProvider(
      child: ChangeNotifierProvider<YatteeAccountProvider>.value(
        value: account,
        child: MaterialApp(theme: monoTheme(dark: true), home: const YouTubeScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (account, server);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(false);
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  testWidgets('shows trending and popular rows and a subscriptions hint without subscriptions', (tester) async {
    final (_, server) = await _pumpYouTube(tester);
    expect(find.byType(HubSection), findsNWidgets(2));
    expect(find.text(t.yattee.rows.trending), findsOneWidget);
    expect(find.text(t.yattee.rows.popular), findsOneWidget);
    expect(find.text(t.yattee.rows.subscriptions), findsNothing);
    expect(find.text(t.yattee.noSubscriptions), findsOneWidget);
    expect(find.text('Trending One'), findsOneWidget);
    expect(server.feedBodies, isEmpty);
  });

  testWidgets('sends the stored subscriptions to the feed and renders the row first', (tester) async {
    final (_, server) = await _pumpYouTube(tester, subscribed: true);
    expect(server.feedBodies, hasLength(1));
    expect(server.feedBodies.single['channels'], [
      {'channel_id': 'UCfeed', 'site': 'youtube', 'channel_name': 'Feed Channel'},
    ]);
    final rows = tester.widgetList<HubSection>(find.byType(HubSection)).map((hub) => hub.hub.title).toList();
    expect(rows, [t.yattee.rows.subscriptions, t.yattee.rows.trending, t.yattee.rows.popular]);
    expect(find.text('Feed One'), findsOneWidget);
  });

  testWidgets('a new subscription reloads only the feed row', (tester) async {
    final (account, server) = await _pumpYouTube(tester);
    expect(server.feedBodies, isEmpty);
    // The subscribe persists through the store and the feed reload it
    // triggers answers in real time, so both settle under runAsync before
    // the fake clock pumps the resulting frame.
    await tester.runAsync(() async {
      await account.subscribe(const YatteeSubscription(channelId: 'UCnew', name: 'New'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(server.feedBodies, hasLength(1));
    expect(find.text(t.yattee.rows.subscriptions), findsOneWidget);
    expect(find.text(t.yattee.noSubscriptions), findsNothing);
  });

  testWidgets('typing a query swaps the rows for mixed search results', (tester) async {
    final (_, server) = await _pumpYouTube(tester);
    await tester.enterText(find.byType(TextField), 'rick');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(server.searchQueries, ['rick']);
    expect(find.byType(HubSection), findsNothing);
    expect(find.text('Search Hit'), findsOneWidget);
    expect(find.text('Search Channel'), findsOneWidget);
  });
}
