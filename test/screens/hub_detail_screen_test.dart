import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/hub_detail_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/app_bar_back_button.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/grid_size_calculator.dart';
import 'package:plezy/widgets/focusable_media_card.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:provider/provider.dart';

import '../test_helpers/paged_fakes.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  group('TV back affordance', () {
    tearDown(() => TvDetectionService.debugSetAppleTVOverride(false));

    // The app bar's chevron is focusable, but nothing on TV navigates to it:
    // Up from the grid lands on the action bar and there is no way left out
    // of it, which left the screen with no selectable exit.
    Future<void> pumpGrid(WidgetTester tester, {required bool tv}) async {
      if (tv) TvDetectionService.debugSetAppleTVOverride(true);
      final items = List.generate(4, (index) => _item(index, backend: MediaBackend.plex));
      final harness = await _createHarness(items, backend: MediaBackend.plex);
      await tester.pumpWidget(
        harness.wrap(
          HubDetailScreen(
            hub: MediaHub(
              id: 'youtube:trending',
              title: 'Trending',
              type: 'clip',
              items: items,
              size: items.length,
              more: true,
            ),
            loadItems: () async => items,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the app bar offers a selectable Back action on TV', (tester) async {
      await pumpGrid(tester, tv: true);
      expect(find.byTooltip(t.common.back), findsOneWidget);
      expect(find.byTooltip(t.libraries.sort), findsOneWidget);
      // Exactly one back affordance: the chevron is replaced, not joined, or
      // the screen shows two arrows and only one of them can be picked.
      expect(find.byType(AppBarBackButton), findsNothing);
    });

    testWidgets('and adds none off TV, where the chevron is reachable', (tester) async {
      await pumpGrid(tester, tv: false);
      expect(find.byTooltip(t.common.back), findsNothing);
      expect(find.byTooltip(t.libraries.sort), findsOneWidget);
    });
  });

  testWidgets('Jellyfin hub advances by raw page size after screen filtering', (tester) async {
    final items = List.generate(
      205,
      (index) => _item(index, libraryId: index.isEven ? '7' : '8', backend: MediaBackend.jellyfin),
    );
    final harness = await _createHarness(items, backend: MediaBackend.jellyfin);

    await tester.pumpWidget(
      harness.wrap(
        HubDetailScreen(
          hub: MediaHub(
            id: 'home.continue',
            title: 'Recent',
            type: 'movie',
            items: items.take(5).toList(),
            size: items.length,
            more: true,
            libraryId: '7',
            serverId: 'server_1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(harness.client.requestedStarts, [0, 200]);
    expect(harness.client.fullHubRequests, 0);
    expect(find.text(t.common.retry), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -30000));
    await tester.pumpAndSettle();
    expect(find.text('Item 204'), findsOneWidget);
    expect(find.text('Item 203'), findsNothing);
  });

  testWidgets('Jellyfin Recently Added fetches every page only as the user reaches the end', (tester) async {
    final items = List.generate(450, (index) => _item(index, backend: MediaBackend.jellyfin));
    final harness = await _createHarness(items, backend: MediaBackend.jellyfin);

    await tester.pumpWidget(
      harness.wrap(
        HubDetailScreen(
          hub: MediaHub(
            id: 'home.recent',
            title: 'Recently Added',
            type: 'mixed',
            items: items.take(20).toList(),
            size: items.length,
            more: true,
            serverId: 'server_1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(harness.client.requestedStarts, [0]);
    expect(harness.client.requestedSizes, [200]);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -50000));
    await tester.pumpAndSettle();
    expect(harness.client.requestedStarts, [0, 200, 400]);
    expect(harness.client.requestedSizes, [200, 200, 50]);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -50000));
    await tester.pumpAndSettle();
    expect(find.text('Item 449'), findsOneWidget);
  });

  testWidgets('Plex hub replaces its preview with the full-hub response', (tester) async {
    final items = List.generate(205, (index) => _item(index, backend: MediaBackend.plex));
    final harness = await _createHarness(items, backend: MediaBackend.plex);

    await tester.pumpWidget(
      harness.wrap(
        HubDetailScreen(
          hub: MediaHub(
            id: '/hubs/home/recentlyAdded',
            title: 'Recently Added',
            type: 'movie',
            items: items.take(5).toList(),
            size: items.length,
            more: true,
            serverId: 'server_1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(harness.client.requestedStarts, [0]);
    expect(harness.client.fullHubRequests, 1);
    expect(find.text(t.common.retry), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -30000));
    await tester.pumpAndSettle();
    expect(find.text('Item 204'), findsOneWidget);
  });

  testWidgets('hub detail grid packs the same columns as a library grid at equal width and density', (tester) async {
    // Regression for #2039: hub detail was the only surface on the
    // padding-aware target-count formula, rendering 5 tiny columns on a 360dp
    // phone at density 2 while home rows and library grids rendered 3.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final items = List.generate(12, (index) => _item(index, backend: MediaBackend.plex));
    final harness = await _createHarness(items, backend: MediaBackend.plex);
    await SettingsService.instance.write(SettingsService.libraryDensity, 2);

    await tester.pumpWidget(
      harness.wrap(
        HubDetailScreen(
          hub: MediaHub(id: 'hub_1', title: 'Hub', type: 'movie', items: items, size: items.length),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cardTops = find
        .byType(MediaCard)
        .evaluate()
        .map((element) => tester.getTopLeft(find.byWidget(element.widget)).dy)
        .toList();
    final renderedColumns = cardTops.where((dy) => dy == cardTops.first).length;

    // The library/home formula for the same cross-axis extent (360dp screen
    // minus the grid's EdgeInsets.all(8)).
    final context = tester.element(find.byType(HubDetailScreen));
    final libraryColumns = GridSizeCalculator.getColumnCount(
      360.0 - 16.0,
      GridSizeCalculator.getMaxCrossAxisExtent(context, 2),
    );

    expect(renderedColumns, libraryColumns);
    expect(renderedColumns, 3);
  });

  group('sorting keeps the highlight on its title', () {
    // The grid pins focus nodes to an index, so re-sorting the item list can
    // leave the highlight on a slot that now renders a different title —
    // Select would then open the wrong item.
    final items = [_titled('z', 'Zulu'), _titled('m', 'Mike'), _titled('a', 'Alpha')];

    Future<void> pumpAndSortByTitle(WidgetTester tester, {required String focusTitle}) async {
      final harness = await _createHarness(items, backend: MediaBackend.plex);
      await tester.pumpWidget(
        harness.wrap(
          HubDetailScreen(
            hub: MediaHub(id: 'hub_1', title: 'Hub', type: 'movie', items: items, size: items.length),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // D-pad session parked on a card.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      _cardFor(tester, focusTitle).focusNode!.requestFocus();
      await tester.pumpAndSettle();
      expect(_cardFor(tester, focusTitle).focusNode!.hasPrimaryFocus, isTrue);

      // Title ascending reorders the hub to Alpha, Mike, Zulu. The pick is
      // applied when the sheet closes.
      await tester.tap(find.byTooltip(t.libraries.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.hubDetail.title));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsOneWidget);
    }

    testWidgets('the highlight follows the item that moved', (tester) async {
      await pumpAndSortByTitle(tester, focusTitle: 'Zulu');

      expect(_cardFor(tester, 'Zulu').focusNode!.hasPrimaryFocus, isTrue);
      expect(_cardFor(tester, 'Alpha').focusNode!.hasPrimaryFocus, isFalse);
    });

    testWidgets('a title that keeps its slot keeps its focus node', (tester) async {
      await pumpAndSortByTitle(tester, focusTitle: 'Mike');

      // Mike sorts back into slot 1: nothing to remap, and nothing may move.
      expect(_cardFor(tester, 'Mike').focusNode!.hasPrimaryFocus, isTrue);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'hub_detail_item_1');
    });
  });
}

MediaItem _item(int index, {required MediaBackend backend, String? libraryId}) => testMediaItem(
  id: 'item_$index',
  backend: backend,
  kind: MediaKind.movie,
  title: 'Item $index',
  libraryId: libraryId,
  serverId: 'server_1',
  serverName: 'Server',
);

MediaItem _titled(String id, String title) => testMediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: title,
  serverId: 'server_1',
  serverName: 'Server',
);

FocusableMediaCard _cardFor(WidgetTester tester, String title) =>
    tester.widget<FocusableMediaCard>(find.ancestor(of: find.text(title), matching: find.byType(FocusableMediaCard)));

Future<_HubHarness> _createHarness(List<MediaItem> items, {required MediaBackend backend}) async {
  await SettingsService.getInstance();
  final client = _PagedHubClient(items, backend: backend);
  final manager = MultiServerManager()..debugRegisterClientForTesting(client);
  final provider = testMultiServerProvider(manager);
  addTearDown(provider.dispose);
  return _HubHarness(client: client, provider: provider);
}

class _HubHarness {
  const _HubHarness({required this.client, required this.provider});

  final _PagedHubClient client;
  final MultiServerProvider provider;

  Widget wrap(Widget child) => TranslationProvider(
    child: ChangeNotifierProvider<MultiServerProvider>.value(
      value: provider,
      child: InputModeTracker(
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: SizedBox(width: 1280, height: 720, child: child),
        ),
      ),
    ),
  );
}

class _PagedHubClient implements MediaServerClient {
  _PagedHubClient(this.items, {required this.backend});

  final List<MediaItem> items;
  final List<int?> requestedStarts = [];
  final List<int?> requestedSizes = [];
  int fullHubRequests = 0;

  @override
  final MediaBackend backend;

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String? get serverName => 'Server';

  @override
  ServerCapabilities get capabilities =>
      backend == MediaBackend.plex ? ServerCapabilities.plex : ServerCapabilities.jellyfin;

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    requestedStarts.add(start);
    requestedSizes.add(size);
    return fakeLibraryPage(items, start: start, size: size);
  }

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async {
    fullHubRequests++;
    return List.unmodifiable(items);
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
