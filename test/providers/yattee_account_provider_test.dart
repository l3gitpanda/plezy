import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/yattee/yattee_session.dart';
import 'package:plezy/providers/yattee/yattee_account_provider.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/yattee/yattee_auth_service.dart';
import 'package:plezy/services/yattee/yattee_store.dart';
import 'package:plezy/services/yattee/yattee_stream_selector.dart';

import '../test_helpers/prefs.dart';

YatteeSession _session() => YatteeSession(
  baseUrl: 'https://yattee.example.com',
  username: 'alice',
  secret: 'hunter2',
  instanceLabel: 'Yattee Server',
  version: '1.0.9',
  createdAt: 1,
);

YatteeAccountProvider _provider({List<Map<String, Object?>>? watched, int status = 200}) => YatteeAccountProvider(
  store: const YatteeStore(),
  authService: YatteeAuthService(
    httpClientFactory: () => MockClient((request) async {
      if (request.url.path == '/api/watched-channels') {
        return http.Response(
          jsonEncode(status == 200 ? (watched ?? const []) : {'detail': 'Admin access required'}),
          status,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(jsonEncode([]), 200, headers: {'content-type': 'application/json'});
    }),
  ),
);

Map<String, Object?> _watched(String id, String name) => {
  'channel_id': id,
  'site': 'youtube',
  'channel_name': name,
  'avatar_url': null,
};

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('adoptSession persists the vault-protected session and binds a client', () async {
    final provider = _provider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged('user-1');
    expect(provider.isConnected, isFalse);
    expect(provider.client, isNull);

    await provider.adoptSession(_session());
    expect(provider.isConnected, isTrue);
    expect(provider.displayName, 'alice');
    expect(provider.client?.baseUrl, 'https://yattee.example.com');

    // The password never reaches the preference store in the clear.
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = prefs.getString('user_user-1_yattee_session')!;
    expect(raw, isNot(contains('hunter2')));
    expect(CredentialVault.isProtected(YatteeSession.decode(raw).secret), isTrue);

    // A fresh provider for the same profile reads it back decrypted.
    final reloaded = _provider();
    addTearDown(reloaded.dispose);
    await reloaded.onActiveProfileChanged('user-1');
    expect(reloaded.session?.secret, 'hunter2');
    expect(reloaded.session?.instanceLabel, 'Yattee Server');
  });

  test('sessions are scoped per profile', () async {
    final provider = _provider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged('user-1');
    await provider.adoptSession(_session());
    await provider.onActiveProfileChanged('user-2');
    expect(provider.isConnected, isFalse);
    await provider.onActiveProfileChanged('user-1');
    expect(provider.isConnected, isTrue);
  });

  test('subscriptions and quality persist and are forgotten with the session', () async {
    final provider = _provider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged('user-1');
    await provider.adoptSession(_session());
    await provider.subscribe(const YatteeSubscription(channelId: 'UC1', name: 'One'));
    await provider.subscribe(const YatteeSubscription(channelId: 'UC2', name: 'Two', avatarUrl: 'https://a/2.jpg'));
    // Duplicate subscribe is a no-op.
    await provider.subscribe(const YatteeSubscription(channelId: 'UC1', name: 'One again'));
    expect(provider.subscriptions.map((s) => s.channelId), ['UC2', 'UC1']);
    expect(provider.isSubscribed('UC1'), isTrue);
    await provider.setQuality(YatteeQuality.p1080);

    final reloaded = _provider();
    addTearDown(reloaded.dispose);
    await reloaded.onActiveProfileChanged('user-1');
    expect(reloaded.subscriptions.map((s) => s.channelId), ['UC2', 'UC1']);
    expect(reloaded.subscriptions.last.avatarUrl, isNull);
    expect(reloaded.subscriptions.first.avatarUrl, 'https://a/2.jpg');
    expect(reloaded.quality, YatteeQuality.p1080);

    await reloaded.unsubscribe('UC2');
    expect(reloaded.isSubscribed('UC2'), isFalse);

    await reloaded.disconnect();
    expect(reloaded.isConnected, isFalse);
    expect(reloaded.subscriptions, isEmpty);

    final afterDisconnect = _provider();
    addTearDown(afterDisconnect.dispose);
    await afterDisconnect.onActiveProfileChanged('user-1');
    expect(afterDisconnect.isConnected, isFalse);
    expect(afterDisconnect.subscriptions, isEmpty);
    // The quality cap is a preference, not instance state, and survives.
    expect(afterDisconnect.quality, YatteeQuality.p1080);
  });

  group('server seeding', () {
    test('adopting a session imports the server\'s channel set', () async {
      final provider = _provider(watched: [_watched('UC1', 'One'), _watched('UC2', 'Two')]);
      addTearDown(provider.dispose);
      await provider.onActiveProfileChanged('user-1');
      await provider.adoptSession(_session());
      // adoptSession fires the seed without awaiting it.
      await pumpEventQueue();
      expect(provider.subscriptions.map((s) => s.channelId), ['UC1', 'UC2']);

      // And it survives a reload, so the next launch does not re-import.
      final reloaded = _provider();
      addTearDown(reloaded.dispose);
      await reloaded.onActiveProfileChanged('user-1');
      expect(reloaded.subscriptions.map((s) => s.channelId), ['UC1', 'UC2']);
    });

    test('seeding merges rather than replacing, so local choices survive', () async {
      final provider = _provider(watched: [_watched('UC1', 'One'), _watched('UCnew', 'New')]);
      addTearDown(provider.dispose);
      await provider.onActiveProfileChanged('user-1');
      await provider.adoptSession(_session());
      await pumpEventQueue();
      await provider.subscribe(const YatteeSubscription(channelId: 'UClocal', name: 'Local only'));

      final added = await provider.seedSubscriptionsFromServer();
      // UC1 and UCnew are already known; nothing new, nothing lost.
      expect(added, 0);
      expect(provider.subscriptions.map((s) => s.channelId), containsAll(['UC1', 'UCnew', 'UClocal']));
      expect(provider.isSubscribed('UClocal'), isTrue);
    });

    test('a non-admin 403 leaves the list untouched instead of failing', () async {
      final provider = _provider(status: 403);
      addTearDown(provider.dispose);
      await provider.onActiveProfileChanged('user-1');
      await provider.adoptSession(_session());
      await pumpEventQueue();
      expect(provider.subscriptions, isEmpty);
      expect(provider.isConnected, isTrue);
    });

    test('a profile that already has subscriptions is not re-seeded', () async {
      final seeded = _provider(watched: [_watched('UC1', 'One')]);
      addTearDown(seeded.dispose);
      await seeded.onActiveProfileChanged('user-1');
      await seeded.adoptSession(_session());
      await pumpEventQueue();
      await seeded.unsubscribe('UC1');
      await seeded.subscribe(const YatteeSubscription(channelId: 'UConly', name: 'Only'));

      // Hydrating a non-empty stored list must not re-import, or the
      // unsubscribe above would be undone on every launch.
      final reloaded = _provider(watched: [_watched('UC1', 'One')]);
      addTearDown(reloaded.dispose);
      await reloaded.onActiveProfileChanged('user-1');
      await pumpEventQueue();
      expect(reloaded.subscriptions.map((s) => s.channelId), ['UConly']);
    });
  });

  test('notifies listeners on subscription changes', () async {
    final provider = _provider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged('user-1');
    var notifications = 0;
    provider.addListener(() => notifications++);
    await provider.subscribe(const YatteeSubscription(channelId: 'UC1', name: 'One'));
    await provider.unsubscribe('UC1');
    await provider.unsubscribe('UC1');
    expect(notifications, 2);
  });
}
