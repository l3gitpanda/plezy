import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/yattee/yattee_session.dart';
import 'package:plezy/models/yattee/yattee_site.dart';
import 'package:plezy/providers/yattee/yattee_account_provider.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/yattee/yattee_auth_service.dart';
import 'package:plezy/services/yattee/yattee_store.dart';

import '../test_helpers/prefs.dart';

YatteeSession _session() => YatteeSession(
  baseUrl: 'https://yattee.example.com',
  username: 'alice',
  secret: 'hunter2',
  instanceLabel: 'Yattee Server',
  version: '1.0.9',
  createdAt: 1,
);

Map<String, Object?> _watched(String id, String name, {String site = 'youtube', String? channelUrl}) => {
  'channel_id': id,
  'site': site,
  'channel_name': name,
  'avatar_url': null,
  'channel_url': ?channelUrl,
};

YatteeAccountProvider _provider({List<Map<String, Object?>>? watched, int status = 200}) => YatteeAccountProvider(
  store: const YatteeStore(),
  authService: YatteeAuthService(
    httpClientFactory: () => MockClient((request) async {
      if (request.url.path == '/api/watched-channels') {
        return http.Response(
          jsonEncode(status == 200 ? (watched ?? const []) : {'detail': 'HTTP $status'}),
          status,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(jsonEncode([]), 200, headers: {'content-type': 'application/json'});
    }),
  ),
);

/// A connected provider whose local list is exactly [subscriptions] — the
/// connect-time seed is allowed to land first, then overwritten, so the test
/// controls both sides of the reconcile.
Future<YatteeAccountProvider> _connected(YatteeAccountProvider provider, List<YatteeSubscription> subscriptions) async {
  await provider.onActiveProfileChanged('user-1');
  await provider.adoptSession(_session());
  await pumpEventQueue();
  for (final existing in [...provider.subscriptions]) {
    await provider.unsubscribe(existing.channelId, site: existing.site);
  }
  for (final subscription in subscriptions.reversed) {
    await provider.subscribe(subscription);
  }
  return provider;
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('a channel the server no longer lists is planned for removal', () async {
    final provider = _provider(watched: [_watched('UC1', 'One')]);
    addTearDown(provider.dispose);
    await _connected(provider, const [
      YatteeSubscription(channelId: 'UC1', name: 'One'),
      YatteeSubscription(channelId: 'UCgone', name: 'Deleted in Yattee'),
    ]);

    final plan = await provider.planSubscriptionSync();

    expect(plan.outcome, YatteeSeedOutcome.imported);
    expect(plan.removed.map((s) => s.channelId), ['UCgone']);
    expect(plan.added, isEmpty);
    // Nothing is applied until the caller says so.
    expect(provider.subscriptions.map((s) => s.channelId), ['UC1', 'UCgone']);

    await provider.applySubscriptionSync(plan);
    expect(provider.subscriptions.map((s) => s.channelId), ['UC1']);
  });

  test('a channel added on the server is planned for addition', () async {
    final provider = _provider(watched: [_watched('UC1', 'One'), _watched('UCnew', 'New')]);
    addTearDown(provider.dispose);
    await _connected(provider, const [YatteeSubscription(channelId: 'UC1', name: 'One')]);

    final plan = await provider.planSubscriptionSync();
    await provider.applySubscriptionSync(plan);

    expect(plan.added.map((s) => s.channelId), ['UCnew']);
    expect(provider.subscriptions.map((s) => s.channelId), ['UC1', 'UCnew']);
  });

  // The whole point of scoping to one site: a Twitch channel is stored with a
  // channel_url the feed cannot synthesise, so replacing it from a global,
  // not-per-user server list would drop something only this device can ask for.
  test('sync leaves the other sites alone', () async {
    final provider = _provider(watched: [_watched('UC1', 'One')]);
    addTearDown(provider.dispose);
    await _connected(provider, const [
      YatteeSubscription(channelId: 'UC1', name: 'One'),
      YatteeSubscription(
        channelId: 'shroud',
        name: 'shroud',
        site: YatteeSite.twitch,
        channelUrl: 'https://www.twitch.tv/shroud',
      ),
    ]);

    final plan = await provider.planSubscriptionSync();
    await provider.applySubscriptionSync(plan);

    expect(plan.removed, isEmpty);
    expect(provider.isSubscribed('shroud', site: YatteeSite.twitch), isTrue);
    expect(provider.subscriptionsFor(YatteeSite.twitch).single.channelUrl, 'https://www.twitch.tv/shroud');
  });

  // The server prunes any channel nothing has asked about for 14 days, so an
  // empty answer is far more likely to be a pruned or restarted instance than
  // a real "unsubscribe from everything".
  test('an empty server list never wipes the local one', () async {
    final provider = _provider(watched: const []);
    addTearDown(provider.dispose);
    await _connected(provider, const [YatteeSubscription(channelId: 'UC1', name: 'One')]);

    final plan = await provider.planSubscriptionSync();

    expect(plan.outcome, YatteeSeedOutcome.empty);
    expect(plan.hasChanges, isFalse);
    await provider.applySubscriptionSync(plan);
    expect(provider.subscriptions.map((s) => s.channelId), ['UC1']);
  });

  test('a list that already matches reports no changes', () async {
    final provider = _provider(watched: [_watched('UC1', 'One')]);
    addTearDown(provider.dispose);
    await _connected(provider, const [YatteeSubscription(channelId: 'UC1', name: 'One')]);

    final plan = await provider.planSubscriptionSync();

    expect(plan.outcome, YatteeSeedOutcome.alreadyKnown);
    expect(plan.hasChanges, isFalse);
  });

  test('a surviving channel takes the server name, so a rename propagates', () async {
    final provider = _provider(watched: [_watched('UC1', 'Renamed On Server')]);
    addTearDown(provider.dispose);
    await _connected(provider, const [YatteeSubscription(channelId: 'UC1', name: 'Old Name')]);

    final plan = await provider.planSubscriptionSync();
    await provider.applySubscriptionSync(plan);

    // A rename is not a membership change, so it needs no confirmation — but
    // it still lands.
    expect(plan.outcome, YatteeSeedOutcome.alreadyKnown);
    expect(provider.subscriptions.single.name, 'Renamed On Server');
  });

  test('a non-admin 403 is reported without touching the list', () async {
    final provider = _provider(status: 403);
    addTearDown(provider.dispose);
    await _connected(provider, const [YatteeSubscription(channelId: 'UC1', name: 'One')]);

    final plan = await provider.planSubscriptionSync();

    expect(plan.outcome, YatteeSeedOutcome.notAdmin);
    await provider.applySubscriptionSync(plan);
    expect(provider.subscriptions.map((s) => s.channelId), ['UC1']);
  });

  test('a server without the channel list route reports unsupported', () async {
    final provider = _provider(status: 404);
    addTearDown(provider.dispose);
    await _connected(provider, const [YatteeSubscription(channelId: 'UC1', name: 'One')]);

    expect((await provider.planSubscriptionSync()).outcome, YatteeSeedOutcome.unsupported);
  });

  test('the synced list survives a rebind of the profile', () async {
    final provider = _provider(watched: [_watched('UC1', 'One')]);
    await _connected(provider, const [
      YatteeSubscription(channelId: 'UC1', name: 'One'),
      YatteeSubscription(channelId: 'UCgone', name: 'Deleted in Yattee'),
    ]);
    await provider.applySubscriptionSync(await provider.planSubscriptionSync());
    provider.dispose();

    final reopened = _provider(watched: [_watched('UC1', 'One')]);
    addTearDown(reopened.dispose);
    await reopened.onActiveProfileChanged('user-1');
    expect(reopened.subscriptions.map((s) => s.channelId), ['UC1']);
  });
}
