import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../models/yattee/yattee_site.dart';
import '../../models/yattee/youtube_media_item.dart';
import '../../models/yattee/yattee_session.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/yattee/youtube_player_navigation.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/bottom_sheet_page_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/overlay_sheet.dart';
import 'youtube_channel_screen.dart';

/// Activate a YouTube stand-in: play a video, open a channel.
///
/// The tap sink for every surface that renders [YouTubeMediaItems] — shelf
/// cards, TV rails, search rows and the shared View-All grid all end up
/// here through [navigateToMediaItem]'s YouTube branch.
Future<void> activateYouTubeItem(BuildContext context, MediaItem item) async {
  final account = context.read<YatteeAccountProvider>();
  final videoId = item.youTubeVideoId;
  if (videoId != null) {
    await navigateToYouTubeVideo(
      context,
      account: account,
      videoId: videoId,
      site: item.youTubeSite,
      videoUrl: youTubePlaybackUrl(item, account),
    );
    return;
  }
  final channelId = item.youTubeChannelId;
  // Only YouTube has a channel page: `/channels/{id}` is one of the
  // Invidious-compatible routes, so a Twitch channel has nothing to open.
  if (channelId != null && item.youTubeSite == YatteeSite.youtube) {
    await openYouTubeChannel(context, channelId: channelId, channelName: item.youTubeChannelName);
  }
}

Future<void> openYouTubeChannel(BuildContext context, {required String channelId, String? channelName}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => YouTubeChannelScreen(channelId: channelId, channelName: channelName),
    ),
  );
}

/// Long-press sheet for a video stand-in: the server-backed context menu
/// would break on an item with no server, so YouTube items get this instead.
Future<void> showYouTubeVideoActions(BuildContext context, MediaItem item) async {
  final videoId = item.youTubeVideoId;
  final site = item.youTubeSite;
  final channelId = item.youTubeChannelId;
  final account = context.read<YatteeAccountProvider>();
  final subscribed = channelId != null && account.isSubscribed(channelId, site: site);
  // A channel page exists only on YouTube: `/channels/{id}` is one of the
  // Invidious-compatible routes and serves nothing else.
  final canOpenChannel = channelId != null && site == YatteeSite.youtube;
  // Unsubscribing needs nothing but the id and site, so it works anywhere.
  // Subscribing does not: every non-YouTube channel needs a `channel_url`
  // the feed cannot synthesise, and a video row does not carry one — those
  // are added by name in the Yattee settings instead.
  final canToggleSubscription = channelId != null && (subscribed || site == YatteeSite.youtube);
  if (videoId == null && !canOpenChannel && !canToggleSubscription) return;
  final action = await OverlaySheetController.showAdaptive<_YouTubeVideoAction>(
    context,
    builder: (sheetContext) => BottomSheetPageScaffold(
      title: item.title ?? '',
      icon: Symbols.smart_display_rounded,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (videoId != null)
            FocusableListTile(
              autofocus: true,
              leading: const AppIcon(Symbols.play_arrow_rounded, fill: 1),
              title: Text(t.common.play),
              onTap: () => OverlaySheetController.closeAdaptive(sheetContext, _YouTubeVideoAction.play),
            ),
          if (canOpenChannel)
            FocusableListTile(
              autofocus: videoId == null,
              leading: const AppIcon(Symbols.account_circle_rounded, fill: 1),
              title: Text(t.yattee.goToChannel),
              subtitle: item.youTubeChannelName == null ? null : Text(item.youTubeChannelName!),
              onTap: () => OverlaySheetController.closeAdaptive(sheetContext, _YouTubeVideoAction.channel),
            ),
          if (canToggleSubscription)
            FocusableListTile(
              autofocus: videoId == null && !canOpenChannel,
              leading: AppIcon(subscribed ? Symbols.notifications_off_rounded : Symbols.notifications_rounded, fill: 1),
              title: Text(subscribed ? t.yattee.unsubscribe : t.yattee.subscribe),
              onTap: () => OverlaySheetController.closeAdaptive(sheetContext, _YouTubeVideoAction.toggleSubscription),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _YouTubeVideoAction.play:
      await navigateToYouTubeVideo(
        context,
        account: account,
        videoId: videoId!,
        site: site,
        videoUrl: youTubePlaybackUrl(item, account),
      );
    case _YouTubeVideoAction.channel:
      await openYouTubeChannel(context, channelId: channelId!, channelName: item.youTubeChannelName);
    case _YouTubeVideoAction.toggleSubscription:
      await toggleYouTubeSubscription(
        context,
        account: account,
        subscription: YatteeSubscription(channelId: channelId!, name: item.youTubeChannelName ?? channelId, site: site),
      );
  }
}

/// The URL to extract [item] from, for a site that is fetched by URL.
///
/// Normally the server states it on the item. When it does not, a live
/// broadcast can still be resolved: on Twitch the channel URL *is* the
/// stream, and the subscription stored an exact one when it was added. That
/// substitution is deliberately limited to live items — for a past broadcast
/// the channel URL points at whatever is on air now, which would quietly play
/// the wrong thing instead of admitting it could not find the right one.
String? youTubePlaybackUrl(MediaItem item, YatteeAccountProvider account) {
  if (item.youTubeVideoUrl case final url?) return url;
  final site = item.youTubeSite;
  if (site == YatteeSite.youtube || !item.youTubeIsLive) return null;
  final channelId = item.youTubeChannelId;
  if (channelId == null) return null;
  for (final subscription in account.subscriptionsFor(site)) {
    if (subscription.channelId == channelId) return subscription.channelUrl;
  }
  return null;
}

/// Subscribe or unsubscribe with a confirmation toast. The list lives in the
/// app (see [YatteeAccountProvider]), so this never touches the server.
Future<void> toggleYouTubeSubscription(
  BuildContext context, {
  required YatteeAccountProvider account,
  required YatteeSubscription subscription,
}) async {
  // Keyed on the site too: the site-less defaults would look past a Twitch
  // channel and silently leave it subscribed.
  final wasSubscribed = account.isSubscribed(subscription.channelId, site: subscription.site);
  if (wasSubscribed) {
    await account.unsubscribe(subscription.channelId, site: subscription.site);
  } else {
    await account.subscribe(subscription);
  }
  if (!context.mounted) return;
  showAppSnackBar(
    context,
    wasSubscribed ? t.yattee.unsubscribed(channel: subscription.name) : t.yattee.subscribed(channel: subscription.name),
  );
}

enum _YouTubeVideoAction { play, channel, toggleSubscription }
