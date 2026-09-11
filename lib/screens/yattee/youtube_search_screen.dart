import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../mixins/debounced_media_search.dart';
import '../../models/yattee/youtube_media_item.dart';
import '../../models/yattee/yattee_video.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../utils/focus_utils.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/focusable_media_card.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/search_input_field.dart';
import '../libraries/state_messages.dart';

/// Turns a mixed `/search` answer into the stand-ins the shared card stack
/// renders: channels first (there are few), then videos. Shared by the
/// pushed TV search screen and the YouTube tab's inline field.
List<MediaItem> youTubeSearchResultsToItems(YatteeSearchResults results) => [
  for (final channel in results.channels) YouTubeMediaItems.fromChannel(channel),
  for (final video in results.videos) YouTubeMediaItems.fromSummary(video),
];

/// Free-text YouTube search, pushed from the tab's TV toolbar —
/// touch/pointer builds search inline on the tab instead. Mirrors
/// [CatalogSearchScreen]: results are stand-ins rendered through the
/// synthesized-MediaItem card stack, so taps play the video or open the
/// channel exactly like the tab's rows.
class YouTubeSearchScreen extends StatefulWidget {
  const YouTubeSearchScreen({super.key});

  @override
  State<YouTubeSearchScreen> createState() => _YouTubeSearchScreenState();
}

class _YouTubeSearchScreenState extends State<YouTubeSearchScreen> with DebouncedMediaSearch {
  @override
  String get searchDebugLabel => 'YouTubeSearch';

  @override
  Future<List<MediaItem>> performSearchQuery(String query) async {
    final client = context.read<YatteeAccountProvider>().client;
    if (client == null) return const [];
    return youTubeSearchResultsToItems(await client.search(query));
  }

  @override
  void initState() {
    super.initState();
    FocusUtils.requestFocusAfterBuild(this, searchFocusNode);
  }

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.yattee.searchHint),
      slivers: [
        SliverToBoxAdapter(
          child: SearchInputField(
            controller: searchController,
            focusNode: searchFocusNode,
            debugLabel: searchDebugLabel,
            hintText: t.yattee.searchHint,
            onNavigateDown: searchResults.isNotEmpty && !isSearching ? firstResultFocusNode.requestFocus : null,
            onEditingComplete: PlatformDetector.isTV() ? handleSearchSubmit : null,
          ),
        ),
        if (isSearching)
          LoadingIndicatorBox.sliver
        else if (!hasSearched)
          SliverFillRemaining(
            child: StateMessageWidget(message: t.yattee.searchPrompt, icon: Symbols.search_rounded, iconSize: 80),
          )
        else if (lastSearchFailed)
          SliverFillRemaining(
            child: StateMessageWidget(message: t.yattee.searchFailed, icon: Symbols.error_rounded, iconSize: 80),
          )
        else if (searchResults.isEmpty)
          SliverFillRemaining(
            child: StateMessageWidget(
              message: t.yattee.searchEmpty(query: lastSearchedQuery),
              icon: Symbols.search_off_rounded,
              iconSize: 80,
            ),
          )
        else
          buildResultsSliver((context, index) {
            final item = searchResults[index];
            return FocusableMediaCard(
              key: Key(item.globalKey),
              item: item,
              forceListMode: true,
              disableScale: true,
              focusNode: index == 0 ? firstResultFocusNode : null,
              onNavigateUp: index == 0 ? searchFocusNode.requestFocus : null,
            );
          }),
      ],
    );
  }
}
