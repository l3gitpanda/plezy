import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../services/yattee/yattee_stream_selector.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import '../settings/settings_utils.dart';

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
