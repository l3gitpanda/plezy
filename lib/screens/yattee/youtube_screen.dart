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
import '../../models/yattee/youtube_media_item.dart';
import '../../models/yattee/yattee_video.dart';
import '../../navigation/main_screen_scope.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../services/settings_service.dart';
import '../../services/yattee/yattee_client.dart';
import '../../utils/app_logger.dart';
import '../../utils/layout_constants.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/focusable_media_card.dart';
import '../../widgets/desktop_app_bar.dart';
import '../../widgets/hub_section.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/search_input_field.dart';
import '../../widgets/settings_builder.dart';
import '../../widgets/toolbar_scrim.dart';
import '../../widgets/tv_browse_rail.dart';
import '../../widgets/tv_spotlight_scaffold.dart';
import '../libraries/state_messages.dart';
import 'youtube_search_screen.dart';
import 'youtube_video_actions.dart';

/// The three shelves of the YouTube tab, in display order.
enum YouTubeRow { subscriptions, trending, popular }

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

  /// A first feed call for channels the server has never crawled answers
  /// `fetching`; retry a bounded number of times before leaving it to a
  /// manual refresh.
  static const int maxFeedRetries = 3;

  late YatteeAccountProvider _account;
  final Map<YouTubeRow, List<MediaItem>> _rows = {};
  bool _loading = true;
  String? _error;
  DateTime? _loadedAt;
  bool _feedFetching = false;
  String? _feedError;
  int _generation = 0;

  /// The subscriptions row reloads on its own whenever the list changes,
  /// independently of a whole-tab load. It needs its own generation: sharing
  /// [_generation] let a subscribe abort an in-flight [_load] and strand the
  /// tab with `_loading` stuck true.
  int _feedGeneration = 0;
  int _feedRetries = 0;
  Timer? _feedRetryTimer;
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
    return youTubeSearchResultsToItems(await client.search(query));
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
    _feedRetryTimer?.cancel();
    _spotlight.dispose();
    super.dispose();
  }

  static int _signatureOf(YatteeAccountProvider account) =>
      Object.hashAll([account.session?.baseUrl, ...account.subscriptions.map((s) => s.channelId)]);

  /// A subscribe/unsubscribe (or a reconnect) only invalidates the feed
  /// row; trending and popular are unaffected.
  void _onAccountChanged() {
    final signature = _signatureOf(_account);
    if (signature == _subscriptionsSignature) return;
    _subscriptionsSignature = signature;
    if (!mounted) return;
    // A newly subscribed channel is usually uncrawled, so this reload needs a
    // fresh retry budget rather than whatever the last one left behind.
    _feedRetryTimer?.cancel();
    _feedRetries = 0;
    unawaited(_loadFeed(++_feedGeneration));
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
        ),
  ];

  static String _rowTitle(YouTubeRow row) => switch (row) {
    YouTubeRow.subscriptions => t.yattee.rows.subscriptions,
    YouTubeRow.trending => t.yattee.rows.trending,
    YouTubeRow.popular => t.yattee.rows.popular,
  };

  static IconData _rowIcon(YouTubeRow row) => switch (row) {
    YouTubeRow.subscriptions => Symbols.subscriptions_rounded,
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
    _feedRetryTimer?.cancel();
    _feedRetries = 0;
    setState(() {
      _loading = _rows.isEmpty;
      _error = null;
      _feedFetching = false;
      _feedError = null;
    });
    // Every row is independent: one failing endpoint must not blank the
    // others, and a whole-tab error only shows when nothing loaded.
    final results = await Future.wait<Object?>([
      _loadFeed(feedGeneration, client: client),
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
      setState(() => _rows[row] = videos.map(YouTubeMediaItems.fromSummary).toList());
      return null;
    } catch (e, stackTrace) {
      appLogger.w('YouTube: ${row.name} row failed to load', error: e, stackTrace: stackTrace);
      return e;
    }
  }

  Future<Object?> _loadFeed(int feedGeneration, {YatteeClient? client}) async {
    final feedClient = client ?? _account.client;
    if (feedClient == null) return null;
    final subscriptions = _account.subscriptions;
    if (subscriptions.isEmpty) {
      if (mounted && feedGeneration == _feedGeneration) {
        setState(() {
          _rows.remove(YouTubeRow.subscriptions);
          _feedFetching = false;
          _feedError = null;
        });
      }
      return null;
    }
    try {
      final page = await feedClient.fetchFeed(subscriptions, limit: feedLimit);
      if (!mounted || feedGeneration != _feedGeneration) return null;
      setState(() {
        _rows[YouTubeRow.subscriptions] = page.videos.map(YouTubeMediaItems.fromSummary).toList();
        _feedFetching = page.isFetching;
        _feedError = null;
      });
      if (page.isFetching && _feedRetries < maxFeedRetries) {
        _feedRetries++;
        _feedRetryTimer?.cancel();
        _feedRetryTimer = Timer(Duration(seconds: (page.etaSeconds ?? 5).clamp(2, 30)), () {
          if (mounted && feedGeneration == _feedGeneration) unawaited(_loadFeed(feedGeneration));
        });
      }
      return null;
    } catch (e, stackTrace) {
      appLogger.w('YouTube: subscriptions feed failed to load', error: e, stackTrace: stackTrace);
      // The other rows may well have loaded, so this never blanks the tab —
      // it surfaces as a hint above them instead of failing silently.
      if (mounted && feedGeneration == _feedGeneration) {
        setState(() {
          _feedFetching = false;
          _feedError = e.toString();
        });
      }
      return e;
    }
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
    if (_feedError case final error?)
      t.yattee.feedFailed(error: error)
    else if (_account.subscriptions.isEmpty)
      t.yattee.noSubscriptions
    else if (_feedFetching)
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
