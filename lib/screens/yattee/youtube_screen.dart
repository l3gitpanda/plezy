import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_action_bar.dart';
import '../../focus/hub_vertical_navigation.dart';
import '../../focus/locked_hub_controller.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../mixins/debounced_media_search.dart';
import '../../mixins/refreshable.dart';
import '../../mixins/tab_visibility_aware.dart';
import '../../models/yattee/yattee_site.dart';
import '../../models/yattee/yattee_video.dart';
import '../../navigation/main_screen_scope.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../services/settings_service.dart';
import '../../services/yattee/yattee_client.dart';
import '../../utils/app_logger.dart';
import '../../utils/layout_constants.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/bottom_sheet_page_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focusable_media_card.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/desktop_app_bar.dart';
import '../../widgets/hub_section.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/search_input_field.dart';
import '../../widgets/settings_builder.dart';
import '../../widgets/toolbar_scrim.dart';
import '../../widgets/tv_browse_rail.dart';
import '../../widgets/tv_spotlight_scaffold.dart';
import '../hub_detail_screen.dart';
import '../libraries/state_messages.dart';
import 'youtube_search_screen.dart';
import 'youtube_video_actions.dart';

/// Rows in display order. [continueWatching] is built from Plezy's own
/// record and needs no request at all; [subscriptions] and [twitch] are both
/// subscription feeds — one per site, because a site is its own category —
/// while [trending] and [popular] are YouTube-only catalog routes with no
/// equivalent anywhere else.
enum YouTubeRow {
  continueWatching(null),
  subscriptions(YatteeSite.youtube),
  twitch(YatteeSite.twitch),
  trending(null),
  popular(null);

  const YouTubeRow(this.feedSite);

  /// The site whose subscription feed fills this row; null for catalog rows.
  final YatteeSite? feedSite;

  static Iterable<YouTubeRow> get feedRows => values.where((row) => row.feedSite != null);
}

/// The YouTube tab: subscriptions, trending and popular rows from the
/// connected Yattee Server. Only mounted while a server is connected (the
/// tab is hidden otherwise, see [NavigationTab.getVisibleTabs]).
///
/// Same shape as [ExploreScreen]: touch/pointer builds carry an inline
/// search field whose results replace the rows while the query is
/// non-empty; TV keeps the toolbar's search action and pushes
/// [YouTubeSearchScreen]. Rows are [MediaHub]s of YouTube stand-ins so the
/// shelf, rail and spotlight stack render them unchanged; activation and
/// long-press are routed to the YouTube sinks instead of server flows.
class YouTubeScreen extends StatefulWidget {
  const YouTubeScreen({super.key});

  @override
  State<YouTubeScreen> createState() => YouTubeScreenState();
}

class YouTubeScreenState extends State<YouTubeScreen>
    with FullRefreshable, TabVisibilityAware, FocusableTab, DebouncedMediaSearch {
  /// Rows reload when the tab is shown after this long.
  static const Duration staleAfter = Duration(minutes: 15);

  /// How many uploads the subscriptions row asks for.
  static const int feedLimit = 50;

  /// How many the View All grid asks for instead. A shelf is a single
  /// scrolling line, so 50 is plenty there; the grid is the browse surface
  /// and shows several rows at once. The server accepts up to 1000, but it
  /// answers out of its own cache — asking for far more than it has crawled
  /// just returns what there is.
  static const int gridFeedLimit = 300;

  /// A first feed call for channels the server has never crawled answers
  /// `fetching`; retry a bounded number of times before leaving it to a
  /// manual refresh.
  static const int maxFeedRetries = 3;

  late YatteeAccountProvider _account;
  final Map<YouTubeRow, List<MediaItem>> _rows = {};
  bool _loading = true;
  String? _error;
  DateTime? _loadedAt;

  /// Keyed by row: each site's feed succeeds, fails and finishes crawling
  /// independently, so one Twitch channel the server cannot reach must not
  /// put an error over the YouTube row.
  final Map<YouTubeRow, bool> _feedFetching = {};
  final Map<YouTubeRow, String> _feedError = {};
  int _generation = 0;

  /// The subscriptions row reloads on its own whenever the list changes,
  /// independently of a whole-tab load. It needs its own generation: sharing
  /// [_generation] let a subscribe abort an in-flight [_load] and strand the
  /// tab with `_loading` stuck true.
  int _feedGeneration = 0;
  final Map<YouTubeRow, int> _feedRetries = {};
  final Map<YouTubeRow, Timer> _feedRetryTimer = {};
  int _subscriptionsSignature = 0;

  /// Per-row focus keys so focus memory survives reloads.
  final Map<YouTubeRow, GlobalKey<HubSectionState>> _hubKeys = {
    for (final row in YouTubeRow.values) row: GlobalKey<HubSectionState>(),
  };
  List<GlobalKey<HubSectionState>> _orderedHubKeys = const [];
  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  final _tvBrowseRailKey = GlobalKey<TvBrowseRailState>();
  final _hubFocusMemory = HubFocusMemory();
  final TvSpotlightController _spotlight = TvSpotlightController();

  @override
  String get searchDebugLabel => 'YouTubeSearch';

  bool get searchIsActive => searchController.text.trim().isNotEmpty;

  @override
  Future<List<MediaItem>> performSearchQuery(String query) async {
    final client = _account.client;
    if (client == null) return const [];
    return youTubeSearchResultsToItems(await client.search(query), _account);
  }

  @override
  void initState() {
    super.initState();
    _account = context.read<YatteeAccountProvider>();
    _subscriptionsSignature = _signatureOf(_account);
    _account.addListener(_onAccountChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _account.removeListener(_onAccountChanged);
    _cancelFeedRetries();
    _spotlight.dispose();
    super.dispose();
  }

  static int _signatureOf(YatteeAccountProvider account) =>
      Object.hashAll([account.session?.baseUrl, ...account.subscriptions.map((s) => '${s.site.id}:${s.channelId}')]);

  /// A subscribe/unsubscribe (or a reconnect) only invalidates the feed
  /// row; trending and popular are unaffected.
  void _onAccountChanged() {
    if (!mounted) return;
    final signature = _signatureOf(_account);
    // A watched mark and a resume point both change only what the client
    // already knows, so both are applied in place; refetching a row to learn
    // something local would be a network round trip for nothing.
    setState(() {
      for (final row in _rows.keys.toList()) {
        _rows[row] = _account.restampWatched(_rows[row]!);
      }
      _syncContinueWatching();
    });
    if (signature == _subscriptionsSignature) return;
    _subscriptionsSignature = signature;
    if (!mounted) return;
    // A newly subscribed channel is usually uncrawled, so this reload needs a
    // fresh retry budget rather than whatever the last one left behind.
    _cancelFeedRetries();
    _feedRetries.clear();
    final feedGeneration = ++_feedGeneration;
    for (final row in YouTubeRow.feedRows) {
      unawaited(_loadFeed(feedGeneration, row));
    }
  }

  List<MediaHub> get _hubs => [
    for (final row in YouTubeRow.values)
      if (_rows[row] case final items? when items.isNotEmpty)
        MediaHub(
          id: 'youtube:${row.name}',
          identifier: 'youtube.${row.name}',
          title: _rowTitle(row),
          type: 'clip',
          items: items,
          size: items.length,
          // Every row opens a View All grid. For the feed rows that is a
          // genuinely deeper page; for trending and popular the server has no
          // paging at all, and the grid is still the better way to read a
          // long list than a one-line shelf.
          more: true,
        ),
  ];

  /// Every video with a resume point, newest first, as cards.
  ///
  /// Not a fetch: the resume points and the video summaries behind them are
  /// Plezy's own record (see [YatteeStore.loadProgress]), so this row costs
  /// nothing and is never out of date.
  List<MediaItem> _continueWatchingItems() => [
    for (final progress in _account.continueWatching) _account.toMediaItem(progress.video),
  ];

  /// Rebuild the Continue Watching row, dropping it when there is nothing to
  /// resume. Call inside a `setState`.
  void _syncContinueWatching() {
    final items = _continueWatchingItems();
    if (items.isEmpty) {
      _rows.remove(YouTubeRow.continueWatching);
    } else {
      _rows[YouTubeRow.continueWatching] = items;
    }
  }

  void _cancelFeedRetries() {
    for (final timer in _feedRetryTimer.values) {
      timer.cancel();
    }
    _feedRetryTimer.clear();
  }

  static String _rowTitle(YouTubeRow row) => switch (row) {
    // The shelf every other surface in the app calls Continue Watching; the
    // string is already translated everywhere.
    YouTubeRow.continueWatching => t.discover.continueWatching,
    YouTubeRow.subscriptions => t.yattee.rows.subscriptions,
    YouTubeRow.twitch => t.yattee.rows.twitch,
    YouTubeRow.trending => t.yattee.rows.trending,
    YouTubeRow.popular => t.yattee.rows.popular,
  };

  static IconData _rowIcon(YouTubeRow row) => switch (row) {
    YouTubeRow.continueWatching => Symbols.resume_rounded,
    YouTubeRow.subscriptions => Symbols.subscriptions_rounded,
    YouTubeRow.twitch => Symbols.sensors_rounded,
    YouTubeRow.trending => Symbols.trending_up_rounded,
    YouTubeRow.popular => Symbols.whatshot_rounded,
  };

  YouTubeRow? _rowForHub(MediaHub hub) {
    for (final row in YouTubeRow.values) {
      if (hub.id == 'youtube:${row.name}') return row;
    }
    return null;
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final feedGeneration = ++_feedGeneration;
    final client = _account.client;
    if (client == null) return;
    _cancelFeedRetries();
    _feedRetries.clear();
    setState(() {
      // Read before the row is (re)built below, so a first load still shows
      // the spinner rather than a lone Continue Watching shelf.
      _loading = _rows.isEmpty;
      _error = null;
      _feedFetching.clear();
      _feedError.clear();
      _syncContinueWatching();
    });
    // Every row is independent: one failing endpoint must not blank the
    // others, and a whole-tab error only shows when nothing loaded.
    final results = await Future.wait<Object?>([
      for (final row in YouTubeRow.feedRows) _loadFeed(feedGeneration, row, client: client),
      _loadRow(generation, YouTubeRow.trending, client.fetchTrending),
      _loadRow(generation, YouTubeRow.popular, client.fetchPopular),
    ]);
    if (!mounted || generation != _generation) return;
    final failures = results.whereType<Object>().toList();
    setState(() {
      _loading = false;
      _loadedAt = DateTime.now();
      _error = failures.length == results.length ? failures.first.toString() : null;
    });
  }

  /// Returns the error when the row failed, null on success.
  Future<Object?> _loadRow(int generation, YouTubeRow row, Future<List<YatteeVideoSummary>> Function() fetch) async {
    try {
      final videos = await fetch();
      if (!mounted || generation != _generation) return null;
      setState(() => _rows[row] = videos.map(_account.toMediaItem).toList());
      return null;
    } catch (e, stackTrace) {
      appLogger.w('YouTube: ${row.name} row failed to load', error: e, stackTrace: stackTrace);
      return e;
    }
  }

  /// Load one site's subscription feed into its row.
  ///
  /// One call per site rather than one merged call: `POST /feed` folds every
  /// channel it is given into a single list, so a shared call could not be
  /// split back into rows — and a site the server has disabled fails the
  /// whole request rather than just its own channels.
  Future<Object?> _loadFeed(int feedGeneration, YouTubeRow row, {YatteeClient? client}) async {
    final site = row.feedSite;
    if (site == null) return null;
    final feedClient = client ?? _account.client;
    if (feedClient == null) return null;
    final subscriptions = _account.subscriptionsFor(site);
    if (subscriptions.isEmpty) {
      if (mounted && feedGeneration == _feedGeneration) {
        setState(() {
          _rows.remove(row);
          _feedFetching.remove(row);
          _feedError.remove(row);
        });
      }
      return null;
    }
    try {
      // A site whose channels are broadcasts is read channel by channel: the
      // feed carries no live flag and serves the thumbnail it cached when the
      // channel was first crawled, so from it every streamer looks offline
      // and frozen at the moment you subscribed.
      if (site.browsesByChannel) {
        final videos = await feedClient.fetchChannelStates(subscriptions);
        if (!mounted || feedGeneration != _feedGeneration) return null;
        setState(() {
          _rows[row] = videos.map(_account.toMediaItem).toList();
          _feedFetching.remove(row);
          _feedError.remove(row);
        });
        return null;
      }
      final page = await feedClient.fetchFeed(subscriptions, limit: feedLimit);
      if (!mounted || feedGeneration != _feedGeneration) return null;
      setState(() {
        _rows[row] = page.videos.map(_account.toMediaItem).toList();
        _feedFetching[row] = page.isFetching;
        _feedError.remove(row);
      });
      if (page.isFetching && (_feedRetries[row] ?? 0) < maxFeedRetries) {
        _feedRetries[row] = (_feedRetries[row] ?? 0) + 1;
        _feedRetryTimer.remove(row)?.cancel();
        _feedRetryTimer[row] = Timer(Duration(seconds: (page.etaSeconds ?? 5).clamp(2, 30)), () {
          if (mounted && feedGeneration == _feedGeneration) unawaited(_loadFeed(feedGeneration, row));
        });
      }
      return null;
    } catch (e, stackTrace) {
      appLogger.w('YouTube: ${site.id} feed failed to load', error: e, stackTrace: stackTrace);
      // The other rows may well have loaded, so this never blanks the tab —
      // it surfaces as a hint above them instead of failing silently.
      if (mounted && feedGeneration == _feedGeneration) {
        setState(() {
          _feedFetching.remove(row);
          _feedError[row] = e.toString();
        });
      }
      return e;
    }
  }

  /// Everything the View All grid should show for [row].
  ///
  /// Deliberately a fresh fetch rather than the shelf's cached list: the feed
  /// rows can go much deeper than the shelf asked for, and re-running the
  /// catalog rows costs one request against a server that caches them.
  ///
  /// Runs outside the tab's generation guards — the grid is its own screen
  /// and its own lifetime, so a tab reload underneath must not cancel it.
  Future<List<MediaItem>> _loadAll(YouTubeRow row) async {
    // The only row with nothing to fetch: it is already everything there is.
    if (row == YouTubeRow.continueWatching) return _continueWatchingItems();
    final client = _account.client;
    if (client == null) return const [];
    final site = row.feedSite;
    if (site != null) {
      final subscriptions = _account.subscriptionsFor(site);
      if (subscriptions.isEmpty) return const [];
      if (site.browsesByChannel) {
        // Deeper per channel than the shelf takes, but still one extraction
        // each — the cost scales with channels followed, not with the page.
        final videos = await client.fetchChannelStates(subscriptions, perChannelLimit: 20);
        return videos.map(_account.toMediaItem).toList();
      }
      final page = await client.fetchFeed(subscriptions, limit: gridFeedLimit);
      return page.videos.map(_account.toMediaItem).toList();
    }
    final videos = switch (row) {
      YouTubeRow.trending => await client.fetchTrending(),
      YouTubeRow.popular => await client.fetchPopular(),
      // Unreachable: every non-feed row is one of the two above.
      _ => const <YatteeVideoSummary>[],
    };
    return videos.map(_account.toMediaItem).toList();
  }

  /// Open the browsable grid for one row, chosen from a sheet.
  ///
  /// Both rails put their own View All in the slot AFTER the last card, which
  /// on a fifty-item shelf is fifty presses away — present, but no way to
  /// find it. This is the discoverable entry, in the toolbar beside search
  /// where focus already starts.
  Future<void> _browseRow() async {
    final rows = [
      for (final row in YouTubeRow.values)
        if (_rows[row]?.isNotEmpty ?? false) row,
    ];
    if (rows.isEmpty) return;
    // One row is not a choice worth a sheet; go straight to it.
    final row = rows.length == 1
        ? rows.single
        : await OverlaySheetController.showAdaptive<YouTubeRow>(
            context,
            builder: (sheetContext) => BottomSheetPageScaffold(
              title: t.common.viewAll,
              icon: Symbols.grid_view_rounded,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < rows.length; i++)
                    FocusableListTile(
                      autofocus: i == 0,
                      leading: AppIcon(_rowIcon(rows[i]), fill: 1),
                      title: Text(_rowTitle(rows[i])),
                      onTap: () => OverlaySheetController.closeAdaptive(sheetContext, rows[i]),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
    if (row == null || !mounted) return;
    MediaHub? target;
    for (final hub in _hubs) {
      if (_rowForHub(hub) == row) {
        target = hub;
        break;
      }
    }
    if (target == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HubDetailScreen(hub: target!, loadItems: () => _loadAll(row)),
      ),
    );
  }

  void _ensureFresh() {
    final loadedAt = _loadedAt;
    if (_loading || (loadedAt != null && DateTime.now().difference(loadedAt) < staleAfter)) return;
    unawaited(_load());
  }

  Future<void> _handleRefresh() {
    final query = searchController.text.trim();
    if (query.isNotEmpty) return runSearch(query);
    return _load();
  }

  @override
  void fullRefresh() {
    searchController.clear();
    unawaited(_load());
  }

  @override
  void onTabShown() => _ensureFresh();

  @override
  void onTabHidden() {}

  @override
  void focusActiveTabIfReady() {
    if (PlatformDetector.isTV()) {
      if (_hubs.isNotEmpty) {
        _tvBrowseRailKey.currentState?.requestFocus();
      } else {
        _actionBarKey.currentState?.requestFocusOnFirst();
      }
      return;
    }
    if (searchIsActive) {
      if (searchResults.isNotEmpty) {
        firstResultFocusNode.requestFocus();
      } else {
        searchFocusNode.requestFocus();
      }
      return;
    }
    _orderedHubKeys.firstOrNull?.currentState?.requestFocusFromMemory();
  }

  void _updateHubKeys(List<MediaHub> hubs) {
    _orderedHubKeys = [for (final hub in hubs) _hubKeys[_rowForHub(hub)!]!];
  }

  bool _handleVerticalNavigation(int hubIndex, bool isUp) {
    final keys = _orderedHubKeys;
    return navigateVerticalHubRows(
      hubCount: keys.length,
      hubIndex: hubIndex,
      isUp: isUp,
      onTopBoundary: searchFocusNode.requestFocus,
      requestFocus: (targetIndex) => keys[targetIndex].currentState?.requestFocusFromMemory(),
    );
  }

  void _navigateToSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  void _activate(MediaItem item) => unawaited(activateYouTubeItem(context, item));

  void _showActions(MediaItem item) => unawaited(showYouTubeVideoActions(context, item));

  @override
  Widget build(BuildContext context) {
    final hubs = _hubs;
    _updateHubKeys(hubs);

    if (PlatformDetector.isTV()) {
      return SettingsBuilder(
        prefs: const [SettingsService.hideSpoilers, SettingsService.libraryDensity, SettingsService.episodePosterMode],
        builder: (context) => _buildTvContent(hubs),
      );
    }

    // One header mode for every state; see ExploreScreen for why the
    // floating/pinned variant must not flip between states.
    Widget appBar() => DesktopSliverAppBar(
      title: Text(t.yattee.title),
      pinned: false,
      floating: true,
      snap: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      scrolledUnderElevation: 0,
      actions: [
        FocusableActionBar(
          key: _actionBarKey,
          onNavigateDown: searchFocusNode.requestFocus,
          actions: [
            FocusableAction(
              icon: Symbols.grid_view_rounded,
              tooltip: t.common.viewAll,
              onPressed: () => unawaited(_browseRow()),
            ),
            FocusableAction(
              icon: Symbols.refresh_rounded,
              tooltip: t.common.refresh,
              onPressed: () => unawaited(_handleRefresh()),
            ),
          ],
        ),
      ],
    );

    Widget searchField() => SliverToBoxAdapter(
      child: SearchInputField(
        controller: searchController,
        focusNode: searchFocusNode,
        debugLabel: searchDebugLabel,
        hintText: t.yattee.searchHint,
        onNavigateLeft: _navigateToSidebar,
        onNavigateDown: _searchFieldDownTarget(),
        onEditingComplete: handleSearchSubmit,
      ),
    );

    Widget scroll(List<Widget> body) =>
        CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [appBar(), searchField(), ...body]);

    Widget content;
    if (searchIsActive) {
      content = scroll([_buildSearchResults()]);
    } else if (hubs.isEmpty && _loading) {
      content = scroll(const [SliverFillRemaining(child: Center(child: CircularProgressIndicator()))]);
    } else if (hubs.isEmpty && _error != null) {
      content = scroll([
        SliverFillRemaining(
          child: ErrorStateWidget(
            message: t.yattee.loadFailed(error: _error!),
            icon: Symbols.error_outline_rounded,
            onRetry: () => unawaited(_load()),
          ),
        ),
      ]);
    } else if (hubs.isEmpty) {
      content = scroll([
        SliverFillRemaining(
          child: EmptyStateWidget(message: t.yattee.emptyMessage, icon: Symbols.smart_display_rounded),
        ),
      ]);
    } else {
      content = scroll([
        for (final hint in _hints) SliverToBoxAdapter(child: _buildHint(hint)),
        for (var i = 0; i < hubs.length; i++)
          SliverToBoxAdapter(
            child: HubSection(
              key: _orderedHubKeys[i],
              hub: hubs[i],
              focusMemory: _hubFocusMemory,
              icon: _rowIcon(_rowForHub(hubs[i])!),
              loadMoreItems: () => _loadAll(_rowForHub(hubs[i])!),
              onItemTap: _activate,
              onItemLongPress: _showActions,
              onVerticalNavigation: (isUp) => _handleVerticalNavigation(i, isUp),
              onNavigateUp: i == 0 ? searchFocusNode.requestFocus : null,
              onNavigateToSidebar: _navigateToSidebar,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ]);
    }

    return Scaffold(
      body: RefreshIndicator(onRefresh: _handleRefresh, child: content),
    );
  }

  /// Status lines shown above the rows, in priority order. Read by BOTH
  /// layouts — the tvOS branch used to render none of these, so a user with
  /// no subscriptions saw the row silently missing with no explanation.
  List<String> get _hints => [
    // One line per failing site rather than one for the tab: "Twitch is
    // unreachable" and "your YouTube feed is still crawling" are different
    // problems and can be true at once.
    for (final row in YouTubeRow.feedRows)
      if (_feedError[row] case final error?) t.yattee.feedFailed(error: error),
    if (_account.subscriptions.isEmpty)
      t.yattee.noSubscriptions
    else if (_feedFetching.values.any((fetching) => fetching))
      t.yattee.feedFetching,
  ];

  Widget _buildHint(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }

  VoidCallback? _searchFieldDownTarget() {
    if (searchIsActive) {
      return searchResults.isNotEmpty && !isSearching ? firstResultFocusNode.requestFocus : null;
    }
    final first = _orderedHubKeys.firstOrNull;
    if (first == null) return null;
    return () => first.currentState?.requestFocusFromMemory();
  }

  Widget _buildSearchResults() {
    if (isSearching) return LoadingIndicatorBox.sliver;
    if (lastSearchFailed) {
      return SliverFillRemaining(
        child: StateMessageWidget(message: t.yattee.searchFailed, icon: Symbols.error_rounded, iconSize: 80),
      );
    }
    if (!hasSearched) return const SliverToBoxAdapter(child: SizedBox.shrink());
    if (searchResults.isEmpty) {
      return SliverFillRemaining(
        child: StateMessageWidget(
          message: t.yattee.searchEmpty(query: lastSearchedQuery),
          icon: Symbols.search_off_rounded,
          iconSize: 80,
        ),
      );
    }
    return buildResultsSliver((context, index) {
      final item = searchResults[index];
      return FocusableMediaCard(
        key: Key(item.globalKey),
        item: item,
        forceListMode: true,
        disableScale: true,
        focusNode: index == 0 ? firstResultFocusNode : null,
        onNavigateLeft: _navigateToSidebar,
        onNavigateUp: index == 0 ? searchFocusNode.requestFocus : null,
      );
    });
  }

  Widget _buildTvToolbar() {
    final foregroundColor = Theme.of(context).colorScheme.onSurface;
    return ToolbarScrim(
      child: Row(
        children: [
          const Spacer(),
          FocusableActionBar(
            key: _actionBarKey,
            onNavigateLeft: _navigateToSidebar,
            onNavigateDown: _tvBrowseRailKey.currentState?.requestFocus,
            onBack: _navigateToSidebar,
            spacing: 4,
            actions: [
              FocusableAction(
                icon: Symbols.search_rounded,
                iconColor: foregroundColor,
                tooltip: t.common.search,
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const YouTubeSearchScreen())),
              ),
              FocusableAction(
                icon: Symbols.grid_view_rounded,
                iconColor: foregroundColor,
                tooltip: t.common.viewAll,
                onPressed: () => unawaited(_browseRow()),
              ),
              FocusableAction(
                icon: Symbols.refresh_rounded,
                iconColor: foregroundColor,
                tooltip: t.common.refresh,
                onPressed: () => unawaited(_load()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTvContent(List<MediaHub> hubs) {
    return TvSpotlightScaffold(
      hubs: hubs,
      spotlightListenable: _spotlight,
      resolveSpotlight: () => _spotlight.resolve(hubs),
      // Stand-ins carry absolute artwork URLs; no server client is involved.
      resolveClient: (_) => null,
      foreground: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          if (hubs.isEmpty && _loading)
            const Center(child: CircularProgressIndicator())
          else if (hubs.isEmpty && _error != null)
            Center(
              child: ErrorStateWidget(
                message: t.yattee.loadFailed(error: _error!),
                icon: Symbols.error_outline_rounded,
                onRetry: () => unawaited(_load()),
              ),
            )
          else if (hubs.isEmpty)
            Center(
              child: EmptyStateWidget(
                message: _hints.firstOrNull ?? t.yattee.emptyMessage,
                subtitle: _account.subscriptions.isEmpty ? t.yattee.subscribeHowTo : null,
                icon: Symbols.smart_display_rounded,
              ),
            ),
          if (_hints.isNotEmpty)
            Positioned(
              left: TvLayoutConstants.shelfHorizontalInset,
              right: TvLayoutConstants.shelfHorizontalInset,
              // Clear of the toolbar overlay, above the browse rail.
              top: 96,
              // Bounded like the spotlight copy it sits above: a long error
              // stretched the full 4K width and read as a banner across the
              // artwork rather than as a status line.
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: TvLayoutConstants.heroContentMaxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final hint in _hints) _buildHint(hint)],
                  ),
                ),
              ),
            ),
          if (hubs.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TvBrowseRail(
                key: _tvBrowseRailKey,
                hubs: hubs,
                focusMemory: _hubFocusMemory,
                iconForHub: (hub, _) => _rowIcon(_rowForHub(hub) ?? YouTubeRow.popular),
                // The rail's own trailing slot is what opens the grid on TV;
                // there is no pointer to click a header link with.
                trailingForHub: (_) => TvRailTrailing.viewAll,
                loadMoreItems: (hub) async {
                  final row = _rowForHub(hub);
                  return row == null ? const <MediaItem>[] : _loadAll(row);
                },
                onFocusedItemChanged: _spotlight.select,
                onActivateItem: (_, item) {
                  _activate(item);
                  return true;
                },
                onNavigateUp: _actionBarKey.currentState?.requestFocusOnFirst,
                onNavigateToSidebar: _navigateToSidebar,
                onBack: _navigateToSidebar,
              ),
            ),
          TvToolbarOverlay(child: _buildTvToolbar()),
        ],
      ),
    );
  }
}
