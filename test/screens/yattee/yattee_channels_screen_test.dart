import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/yattee/yattee_session.dart';
import 'package:plezy/models/yattee/yattee_site.dart';
import 'package:plezy/providers/yattee/yattee_account_provider.dart';
import 'package:plezy/screens/yattee/yattee_channels_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/yattee/yattee_store.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

Future<YatteeAccountProvider> _pump(WidgetTester tester, List<YatteeSubscription> subscriptions) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final account = YatteeAccountProvider(store: const YatteeStore());
  addTearDown(account.dispose);
  await tester.runAsync(() async {
    await account.onActiveProfileChanged('user-1');
    for (final subscription in subscriptions.reversed) {
      await account.subscribe(subscription);
    }
  });
  await tester.pumpWidget(
    TranslationProvider(
      child: ChangeNotifierProvider<YatteeAccountProvider>.value(
        value: account,
        child: MaterialApp(theme: monoTheme(dark: true), home: const YatteeChannelsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return account;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  setUp(() async {
    resetSharedPreferencesForTest();
    // A tap in one test starts a preference write inside the fake-async zone;
    // without this the shared queue is still holding it when the next test
    // tries to subscribe.
    YatteeStore.resetForTesting();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('lists every subscribed channel, grouped by site', (tester) async {
    await _pump(tester, const [
      YatteeSubscription(channelId: 'UC1', name: 'A YouTube Channel'),
      YatteeSubscription(
        channelId: 'twitch-123',
        name: 'A Twitch Channel',
        site: YatteeSite.twitch,
        channelUrl: 'https://www.twitch.tv/shroud',
      ),
    ]);

    expect(find.text('A YouTube Channel'), findsOneWidget);
    expect(find.text('A Twitch Channel'), findsOneWidget);
  });

  // The long-press sheet on a video card was the only way to unsubscribe, and
  // it is unreachable for a channel that has stopped showing videos — which is
  // exactly when you want it gone.
  testWidgets('removing a channel unsubscribes it after confirmation', (tester) async {
    final account = await _pump(tester, const [YatteeSubscription(channelId: 'UC1', name: 'A YouTube Channel')]);

    await tester.tap(find.text('A YouTube Channel'));
    await tester.pumpAndSettle();
    expect(find.text(t.yattee.removeChannel(channel: 'A YouTube Channel')), findsOneWidget);

    await tester.tap(find.text(t.yattee.unsubscribe));
    await tester.pumpAndSettle();

    expect(account.isSubscribed('UC1'), isFalse);
    expect(find.text('A YouTube Channel'), findsNothing);
    expect(find.text(t.yattee.manageChannelsEmpty), findsOneWidget);
  });

  testWidgets('cancelling leaves the channel subscribed', (tester) async {
    final account = await _pump(tester, const [YatteeSubscription(channelId: 'UC1', name: 'A YouTube Channel')]);

    await tester.tap(find.text('A YouTube Channel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.common.cancel));
    await tester.pumpAndSettle();

    expect(account.isSubscribed('UC1'), isTrue);
    expect(find.text('A YouTube Channel'), findsOneWidget);
  });
}
