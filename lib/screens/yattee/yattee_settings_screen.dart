import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/yattee/yattee_session.dart';
import '../../models/yattee/yattee_site.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../services/yattee/yattee_exceptions.dart';
import '../../services/yattee/yattee_stream_selector.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import '../settings/settings_utils.dart';
import 'yattee_channels_screen.dart';

/// Connected-state settings for the Yattee Server: who is signed in, which
/// instance, the playback quality cap, and disconnect.
class YatteeSettingsScreen extends StatelessWidget {
  const YatteeSettingsScreen({super.key});

  /// Localized label for a [YatteeQuality] value.
  static String qualityLabel(YatteeQuality quality) => switch (quality) {
    YatteeQuality.best => t.yattee.qualityBest,
    YatteeQuality.p2160 => t.yattee.quality2160,
    YatteeQuality.p1440 => t.yattee.quality1440,
    YatteeQuality.p1080 => t.yattee.quality1080,
    YatteeQuality.p720 => t.yattee.quality720,
    YatteeQuality.p480 => t.yattee.quality480,
    YatteeQuality.p360 => t.yattee.quality360,
  };

  Future<void> _pickQuality(BuildContext context, YatteeAccountProvider account) async {
    final picked = await showSelectionDialog<YatteeQuality>(
      context: context,
      title: t.yattee.quality,
      options: [for (final quality in YatteeQuality.values) DialogOption(value: quality, title: qualityLabel(quality))],
      currentValue: account.quality,
    );
    if (picked == null) return;
    await account.setQuality(picked.value);
  }

  /// Manual re-run of the connect-time seed, for a user whose server list was
  /// empty or stale then — the server drops channels nothing has asked about
  /// for 14 days, so a later Yattee refresh can make new ones appear.
  Future<void> _importChannels(BuildContext context, YatteeAccountProvider account) async {
    final result = await account.seedSubscriptionsFromServer();
    if (!context.mounted) return;
    // Every unsuccessful outcome needs something different from the user, so
    // each one says what rather than collapsing into "nothing to import".
    final message = switch (result.outcome) {
      YatteeSeedOutcome.imported => t.yattee.importedChannels(n: result.added),
      YatteeSeedOutcome.alreadyKnown => t.yattee.importedNothing,
      YatteeSeedOutcome.empty => t.yattee.seedEmpty,
      YatteeSeedOutcome.notAdmin => t.yattee.seedNotAdmin,
      YatteeSeedOutcome.unsupported => t.yattee.seedUnsupported,
      YatteeSeedOutcome.failed => t.yattee.seedFailed(error: result.error ?? ''),
    };
    showAppSnackBar(
      context,
      message,
      // The diagnostic messages are long and actionable; the default is not
      // enough time to read one on a TV across the room.
      duration: result.outcome == YatteeSeedOutcome.imported ? null : const Duration(seconds: 10),
    );
  }

  /// Reconcile the YouTube channel list against the server's, removals
  /// included — the part [_importChannels] deliberately will not do.
  ///
  /// The plan is worked out and shown before anything is applied, because
  /// this is the one action here that can take channels away.
  Future<void> _syncChannels(BuildContext context, YatteeAccountProvider account) async {
    // Reading the channel list is a round trip, and the first thing the user
    // would otherwise see is a dialog appearing out of nowhere some seconds
    // after the tap.
    final loading = ScopedLoadingDialogController()
      ..show(
        context,
        builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
      );
    final YatteeSyncPlan plan;
    try {
      plan = await account.planSubscriptionSync();
    } finally {
      await loading.dismiss();
    }
    if (!context.mounted) return;
    if (plan.outcome != YatteeSeedOutcome.imported) {
      // Nothing to confirm, but an already-matching plan still carries the
      // server's current names — adopt them before reporting.
      if (plan.outcome == YatteeSeedOutcome.alreadyKnown) await account.applySubscriptionSync(plan);
      if (!context.mounted) return;
      showAppSnackBar(context, switch (plan.outcome) {
        YatteeSeedOutcome.alreadyKnown => t.yattee.syncUnchanged,
        YatteeSeedOutcome.empty => t.yattee.syncEmpty,
        YatteeSeedOutcome.notAdmin => t.yattee.seedNotAdmin,
        YatteeSeedOutcome.unsupported => t.yattee.seedUnsupported,
        // Unreachable: `imported` is the branch below.
        YatteeSeedOutcome.imported || YatteeSeedOutcome.failed => t.yattee.seedFailed(error: plan.error ?? ''),
      }, duration: plan.outcome == YatteeSeedOutcome.alreadyKnown ? null : const Duration(seconds: 10));
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: t.yattee.syncConfirm,
      message: t.yattee.syncConfirmBody(added: plan.added.length, removed: plan.removed.length),
      confirmText: t.yattee.syncApply,
      isDestructive: plan.removed.isNotEmpty,
    );
    if (!confirmed) return;
    await account.applySubscriptionSync(plan);
    if (!context.mounted) return;
    showAppSnackBar(context, t.yattee.syncedChannels(added: plan.added.length, removed: plan.removed.length));
  }

  /// Subscribe to a Twitch channel by name.
  ///
  /// Typing a name is the only way in: `/search` serves YouTube alone (it
  /// takes no site parameter at all), so there is nothing to browse. The name
  /// is resolved through `/extract/channel` before it is stored, which both
  /// confirms the channel exists and yields the canonical id and URL — the
  /// feed needs a real `channel_url` for every non-YouTube channel and cannot
  /// synthesise one.
  Future<void> _addTwitchChannel(BuildContext context, YatteeAccountProvider account) async {
    final client = account.client;
    if (client == null) return;
    final entered = await showTextInputDialog(
      context,
      title: t.yattee.addTwitchChannel,
      labelText: t.yattee.twitchChannelLabel,
      hintText: t.yattee.twitchChannelHint,
      validator: (value) =>
          YatteeSite.channelUrlFor(YatteeSite.twitch, value) == null ? t.yattee.twitchChannelInvalid : null,
    );
    if (entered == null || !context.mounted) return;
    final url = YatteeSite.channelUrlFor(YatteeSite.twitch, entered);
    if (url == null) return;

    final loading = ScopedLoadingDialogController()
      ..show(
        context,
        builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
      );
    try {
      final channel = await client.extractChannel(url);
      await loading.dismiss();
      if (!context.mounted) return;
      final name = channel.author.isNotEmpty ? channel.author : entered.trim();
      // yt-dlp does not always report an id; the URL is what the feed
      // actually uses, so the name stands in as a stable-enough key.
      final channelId = channel.authorId.isNotEmpty ? channel.authorId : name;
      await account.subscribe(
        YatteeSubscription(
          channelId: channelId,
          name: name,
          site: YatteeSite.twitch,
          channelUrl: channel.authorUrl.isNotEmpty ? channel.authorUrl : url,
        ),
      );
      if (context.mounted) showAppSnackBar(context, t.yattee.subscribed(channel: name));
    } catch (e, stackTrace) {
      appLogger.w('Yattee: could not resolve the Twitch channel', error: e, stackTrace: stackTrace);
      await loading.dismiss();
      if (!context.mounted) return;
      final message = switch (e) {
        YatteeApiException(:final message) => message,
        _ => e.toString(),
      };
      showErrorSnackBar(context, t.yattee.twitchChannelFailed(error: message));
    } finally {
      unawaited(loading.dismiss());
    }
  }

  Future<void> _disconnect(BuildContext context, YatteeAccountProvider account) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.yattee.disconnectConfirm,
      message: t.yattee.disconnectConfirmBody,
      confirmText: t.common.disconnect,
      isDestructive: true,
    );
    if (!confirmed) return;
    await account.disconnect();
    // build()'s post-frame handler pops the screen once the provider rebuilds
    // with isConnected == false — don't pop here too.
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<YatteeAccountProvider>(
      builder: (context, account, _) {
        final session = account.session;
        // Safety net: the Services hub row is the entry point for reconnecting.
        if (session == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).pop();
          });
          return SettingsPage(title: Text(t.services.names.yattee), children: const []);
        }
        final errorColor = Theme.of(context).colorScheme.error;
        return SettingsPage(
          title: Text(t.services.names.yattee),
          children: [
            SettingsGroup(
              children: [
                ListTile(
                  leading: const AppIcon(Symbols.account_circle_rounded, fill: 1),
                  title: Text(t.yattee.connectedAs(username: session.username)),
                ),
                ListTile(
                  leading: const AppIcon(Symbols.dns_rounded, fill: 1),
                  title: Text(session.instanceLabel.isNotEmpty ? session.instanceLabel : t.yattee.instance),
                  subtitle: Text(
                    session.version.isNotEmpty ? '${session.baseUrl} · ${session.version}' : session.baseUrl,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              children: [
                FocusableListTile(
                  leading: const AppIcon(Symbols.high_quality_rounded, fill: 1),
                  title: Text(t.yattee.quality),
                  subtitle: Text('${qualityLabel(account.quality)} · ${t.yattee.qualityDescription}'),
                  onTap: () => unawaited(_pickQuality(context, account)),
                ),
                FocusableListTile(
                  leading: const AppIcon(Symbols.cloud_download_rounded, fill: 1),
                  title: Text(t.yattee.importChannels),
                  subtitle: Text(t.yattee.importChannelsDescription),
                  onTap: () => unawaited(_importChannels(context, account)),
                ),
                FocusableListTile(
                  leading: const AppIcon(Symbols.sync_rounded, fill: 1),
                  title: Text(t.yattee.syncChannels),
                  subtitle: Text(t.yattee.syncChannelsDescription),
                  onTap: () => unawaited(_syncChannels(context, account)),
                ),
                FocusableListTile(
                  leading: const AppIcon(Symbols.subscriptions_rounded, fill: 1),
                  title: Text(t.yattee.manageChannels),
                  subtitle: Text(t.yattee.manageChannelsCount(n: account.subscriptions.length)),
                  onTap: () => unawaited(
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const YatteeChannelsScreen())),
                  ),
                ),
                FocusableListTile(
                  leading: const AppIcon(Symbols.sensors_rounded, fill: 1),
                  title: Text(t.yattee.addTwitchChannel),
                  subtitle: Text(t.yattee.addTwitchChannelDescription),
                  onTap: () => unawaited(_addTwitchChannel(context, account)),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              children: [
                FocusableListTile(
                  leading: AppIcon(Symbols.link_off_rounded, fill: 1, color: errorColor),
                  title: Text(t.common.disconnect, style: TextStyle(color: errorColor)),
                  onTap: () => unawaited(_disconnect(context, account)),
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
