import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/yattee/yattee_session.dart';
import '../../models/yattee/yattee_site.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import '../libraries/state_messages.dart';

/// Every channel this profile follows, with a way to stop following one.
///
/// Until this existed the only way to unsubscribe was to long-press one of
/// the channel's videos on a shelf — which fails in exactly the case that
/// makes you want to unsubscribe, because a channel that has stopped
/// producing videos (or that the server can no longer read) has no card to
/// long-press.
class YatteeChannelsScreen extends StatelessWidget {
  const YatteeChannelsScreen({super.key});

  static IconData _icon(YatteeSite site) => switch (site) {
    YatteeSite.youtube => Symbols.smart_display_rounded,
    YatteeSite.twitch => Symbols.sensors_rounded,
  };

  Future<void> _remove(BuildContext context, YatteeAccountProvider account, YatteeSubscription subscription) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.yattee.removeChannel(channel: subscription.name),
      message: t.yattee.removeChannelBody,
      confirmText: t.yattee.unsubscribe,
      isDestructive: true,
    );
    if (!confirmed) return;
    await account.unsubscribe(subscription.channelId, site: subscription.site);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<YatteeAccountProvider>(
      builder: (context, account, _) {
        // Grouped by site, and within a site in the order they were stored:
        // the rows on the tab are per site too, so this reads the same way.
        final subscriptions = [for (final site in YatteeSite.values) ...account.subscriptionsFor(site)];
        return SettingsPage(
          title: Text(t.yattee.manageChannels),
          children: [
            if (subscriptions.isEmpty)
              EmptyStateWidget(icon: Symbols.subscriptions_rounded, message: t.yattee.manageChannelsEmpty)
            else
              SettingsGroup(
                children: [
                  for (final subscription in subscriptions)
                    FocusableListTile(
                      leading: AppIcon(_icon(subscription.site), fill: 1),
                      title: Text(subscription.name),
                      subtitle: Text(subscription.channelId),
                      trailing: const AppIcon(Symbols.close_rounded),
                      onTap: () => unawaited(_remove(context, account, subscription)),
                    ),
                ],
              ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}
