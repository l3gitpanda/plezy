import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
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
    await navigateToYouTubeVideo(context, account: account, videoId: videoId);
    return;
  }
  final channelId = item.youTubeChannelId;
  if (channelId != null) await openYouTubeChannel(context, channelId: channelId, channelName: item.youTubeChannelName);
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
  final channelId = item.youTubeChannelId;
  if (videoId == null && channelId == null) return;
  final account = context.read<YatteeAccountProvider>();
  final subscribed = channelId != null && account.isSubscribed(channelId);
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
          if (channelId != null) ...[
            FocusableListTile(
              autofocus: videoId == null,
              leading: const AppIcon(Symbols.account_circle_rounded, fill: 1),
              title: Text(t.yattee.goToChannel),
              subtitle: item.youTubeChannelName == null ? null : Text(item.youTubeChannelName!),
              onTap: () => OverlaySheetController.closeAdaptive(sheetContext, _YouTubeVideoAction.channel),
            ),
            FocusableListTile(
              leading: AppIcon(subscribed ? Symbols.notifications_off_rounded : Symbols.notifications_rounded, fill: 1),
              title: Text(subscribed ? t.yattee.unsubscribe : t.yattee.subscribe),
              onTap: () => OverlaySheetController.closeAdaptive(sheetContext, _YouTubeVideoAction.toggleSubscription),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _YouTubeVideoAction.play:
      await navigateToYouTubeVideo(context, account: account, videoId: videoId!);
    case _YouTubeVideoAction.channel:
      await openYouTubeChannel(context, channelId: channelId!, channelName: item.youTubeChannelName);
    case _YouTubeVideoAction.toggleSubscription:
      await toggleYouTubeSubscription(
        context,
        account: account,
        subscription: YatteeSubscription(channelId: channelId!, name: item.youTubeChannelName ?? channelId),
      );
  }
}

/// Subscribe or unsubscribe with a confirmation toast. The list lives in the
/// app (see [YatteeAccountProvider]), so this never touches the server.
Future<void> toggleYouTubeSubscription(
  BuildContext context, {
  required YatteeAccountProvider account,
  required YatteeSubscription subscription,
}) async {
  final wasSubscribed = account.isSubscribed(subscription.channelId);
  if (wasSubscribed) {
    await account.unsubscribe(subscription.channelId);
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
