import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../mixins/mounted_set_state_mixin.dart';
import '../../models/yattee/youtube_media_item.dart';
import '../../models/yattee/yattee_session.dart';
import '../../models/yattee/yattee_video.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../services/yattee/yattee_client.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_media_card.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/optimized_media_image.dart';
import '../libraries/state_messages.dart';
import 'youtube_video_actions.dart';

/// A YouTube channel: avatar, name, subscriber count, a subscribe toggle and
/// the uploads list, paged through the server's opaque continuation.
///
/// Uploads render as list-mode cards rather than a grid: the list needs no
/// per-slot focus bookkeeping, so D-pad traversal comes from the framework
/// and every row still lands in the shared YouTube tap sink.
class YouTubeChannelScreen extends StatefulWidget {
  final String channelId;

  /// Known before the channel loads (a video's author); shown in the app
  /// bar until `/channels/{id}` answers.
  final String? channelName;

  const YouTubeChannelScreen({super.key, required this.channelId, this.channelName});

  @override
  State<YouTubeChannelScreen> createState() => _YouTubeChannelScreenState();
}

class _YouTubeChannelScreenState extends State<YouTubeChannelScreen> with MountedSetStateMixin {
  /// Rows from the end at which the next page is requested.
  static const int _loadMoreThreshold = 6;

  YatteeChannel? _channel;
  final List<MediaItem> _videos = [];
  String? _continuation;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _generation = 0;
  final _subscribeFocus = FocusNode(debugLabel: 'YouTubeChannel:Subscribe');

  YatteeClient? get _client => context.read<YatteeAccountProvider>().client;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _subscribeFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final client = _client;
    if (client == null) return;
    setStateIfMounted(() {
      _loading = true;
      _error = null;
    });
    try {
      final (channel, page) = await (
        client.fetchChannel(widget.channelId),
        client.fetchChannelVideos(widget.channelId),
      ).wait;
      if (!mounted || generation != _generation) return;
      setState(() {
        _channel = channel;
        _videos
          ..clear()
          ..addAll(page.videos.map(YouTubeMediaItems.fromSummary));
        _continuation = page.continuation;
        _loading = false;
      });
    } catch (e, stackTrace) {
      appLogger.w('YouTube: channel ${widget.channelId} failed to load', error: e, stackTrace: stackTrace);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    final continuation = _continuation;
    final client = _client;
    if (continuation == null || _loadingMore || client == null) return;
    final generation = _generation;
    _loadingMore = true;
    try {
      final page = await client.fetchChannelVideos(widget.channelId, continuation: continuation);
      if (!mounted || generation != _generation) return;
      final known = {for (final item in _videos) item.id};
      setState(() {
        _videos.addAll(page.videos.map(YouTubeMediaItems.fromSummary).where((item) => known.add(item.id)));
        // A backend that echoes the same cursor would page forever; treat it
        // as the end.
        _continuation = page.continuation == continuation ? null : page.continuation;
      });
    } catch (e) {
      appLogger.w('YouTube: channel ${widget.channelId} page failed to load', error: e);
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _toggleSubscription(YatteeAccountProvider account) async {
    final channel = _channel;
    await toggleYouTubeSubscription(
      context,
      account: account,
      subscription: YatteeSubscription(
        channelId: widget.channelId,
        name: channel?.author ?? widget.channelName ?? widget.channelId,
        avatarUrl: channel?.avatar?.url,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<YatteeAccountProvider>();
    final channel = _channel;
    final subscribed = account.isSubscribed(widget.channelId);
    return FocusedScrollScaffold(
      title: Text(channel?.author ?? widget.channelName ?? ''),
      slivers: [
        if (channel != null) SliverToBoxAdapter(child: _buildHeader(context, channel, account, subscribed)),
        if (_loading)
          LoadingIndicatorBox.sliver
        else if (_error != null)
          SliverFillRemaining(
            child: ErrorStateWidget(
              message: t.yattee.channelLoadFailed(error: _error!),
              icon: Symbols.error_outline_rounded,
              onRetry: () => unawaited(_load()),
            ),
          )
        else if (_videos.isEmpty)
          SliverFillRemaining(
            child: EmptyStateWidget(message: t.yattee.emptyMessage, icon: Symbols.smart_display_rounded),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            sliver: SliverList.builder(
              itemCount: _videos.length + (_continuation != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _videos.length) {
                  unawaited(_loadMore());
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: LoadingIndicatorBox()),
                  );
                }
                if (index >= _videos.length - _loadMoreThreshold) unawaited(_loadMore());
                final item = _videos[index];
                return FocusableMediaCard(
                  key: Key(item.globalKey),
                  item: item,
                  forceListMode: true,
                  disableScale: true,
                  onNavigateUp: index == 0 ? _subscribeFocus.requestFocus : null,
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, YatteeChannel channel, YatteeAccountProvider account, bool subscribed) {
    final theme = Theme.of(context);
    final subtitle =
        channel.subCountText ??
        (channel.subCount == null
            ? null
            : t.yattee.subscribers(count: YouTubeMediaItems.formatCompactCount(channel.subCount!)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          ClipOval(
            child: SizedBox(
              width: 72,
              height: 72,
              child: OptimizedMediaImage(
                imagePath: channel.avatar?.url,
                fit: BoxFit.cover,
                fallbackIcon: Symbols.account_circle_rounded,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        channel.author,
                        style: theme.textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (channel.verified) ...[
                      const SizedBox(width: 4),
                      const AppIcon(Symbols.verified_rounded, fill: 1, size: 18),
                    ],
                  ],
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                const SizedBox(height: 8),
                FocusableButton(
                  focusNode: _subscribeFocus,
                  autofocus: true,
                  useBackgroundFocus: true,
                  onPressed: () => unawaited(_toggleSubscription(account)),
                  child: subscribed
                      ? OutlinedButton.icon(
                          onPressed: () => unawaited(_toggleSubscription(account)),
                          icon: const AppIcon(Symbols.notifications_off_rounded, fill: 1),
                          label: Text(t.yattee.unsubscribe),
                        )
                      : FilledButton.icon(
                          onPressed: () => unawaited(_toggleSubscription(account)),
                          icon: const AppIcon(Symbols.notifications_rounded, fill: 1),
                          label: Text(t.yattee.subscribe),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
