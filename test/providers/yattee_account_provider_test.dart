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

YatteeAccountProvider _provider() => YatteeAccountProvider(
  store: const YatteeStore(),
  authService: YatteeAuthService(httpClientFactory: () => MockClient((_) async => http.Response(jsonEncode([]), 200))),
);

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
