import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mixins/disposable_change_notifier_mixin.dart';
import '../../models/yattee/yattee_session.dart';
import '../../services/yattee/yattee_auth_service.dart';
import '../../services/yattee/yattee_client.dart';
import '../../services/yattee/yattee_exceptions.dart';
import '../../services/yattee/yattee_store.dart';
import '../../services/yattee/yattee_stream_selector.dart';
import '../../utils/app_logger.dart';

/// Why a subscription seed produced what it did.
///
/// Yattee Server gates its channel list behind an admin account and prunes
/// channels nothing has asked about for 14 days, so an empty result has
/// several very different causes. Collapsing them into "nothing to import"
/// leaves the user with no idea what to do next.
enum YatteeSeedOutcome {
  /// Channels were added to the local list.
  imported,

  /// The server listed channels, but every one was already subscribed here.
  alreadyKnown,

  /// The server's channel list is empty — nothing has posted a feed to it
  /// recently, or its entries aged out.
  empty,

  /// HTTP 403: the signed-in account is not an administrator of the server.
  notAdmin,

  /// HTTP 404: this server predates the admin channel list.
  unsupported,

  /// Anything else — transport failure, unexpected status.
  failed,
}

/// Outcome of [YatteeAccountProvider.seedSubscriptionsFromServer].
class YatteeSeedResult {
  final YatteeSeedOutcome outcome;

  /// How many channels were added; zero for every non-[YatteeSeedOutcome.imported] outcome.
  final int added;

  /// Server-supplied detail for [YatteeSeedOutcome.failed].
  final String? error;

  const YatteeSeedResult(this.outcome, {this.added = 0, this.error});
}

/// Owns the active Yattee Server session for the currently-selected profile,
/// mirroring [SeerrAccountProvider]'s rebind shape: `onActiveProfileChanged`
/// loads the profile's stored session, subscriptions and quality cap and
/// rebuilds the API client.
///
/// The connect screen drives [YatteeAuthService] itself and hands the
/// finished session to [adoptSession]. Subscriptions live here rather than
/// on the server because Yattee Server's feed endpoint is stateless — it
/// expects the full channel list on every call — and the server keeps no
/// per-user list to sync against. [seedSubscriptionsFromServer] borrows the
/// server's global channel set once so a new device does not start empty.
class YatteeAccountProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  YatteeAccountProvider({YatteeStore? store, YatteeAuthService? authService})
    : _store = store ?? const YatteeStore(),
      authService = authService ?? YatteeAuthService();

  final YatteeStore _store;
  final YatteeAuthService authService;

  YatteeSession? _session;
  YatteeClient? _client;
  List<YatteeSubscription> _subscriptions = const [];
  YatteeQuality _quality = YatteeQuality.best;
  String _activeUserUuid = '';
  int _bindingGeneration = 0;

  YatteeSession? get session => _session;
  bool get isConnected => _session != null;
  String? get displayName => _session?.username;

  /// API client for the browse and playback surfaces; null when disconnected.
  YatteeClient? get client => _client;

  List<YatteeSubscription> get subscriptions => _subscriptions;

  YatteeQuality get quality => _quality;

  void _logPersistenceFailure(Object e) => appLogger.w('Yattee: persistence failed', error: e);

  /// Called whenever the active profile changes (or on initial load).
  Future<void> onActiveProfileChanged(String? newUserUuid) async {
    if (isDisposed) return;
    final userUuid = newUserUuid ?? '';
    final generation = ++_bindingGeneration;
    _activeUserUuid = userUuid;
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    final loaded = await _store.loadSession(userUuid);
    if (!_isCurrentBinding(userUuid, generation)) return;
    // Quality is a preference and outlives a disconnect; the subscription
    // list does not — `clearSession` drops it with the session it belonged to.
    final subscriptions = await _store.loadSubscriptions(userUuid);
    final quality = await _store.loadQuality(userUuid);
    if (!_isCurrentBinding(userUuid, generation)) return;
    _subscriptions = subscriptions;
    _quality = quality;
    _setSessionAndRebind(userUuid, generation, loaded);
    // Nothing stored yet on this device: try the server's channel set so the
    // Subscriptions row is populated without the user re-subscribing by hand.
    if (loaded != null && subscriptions.isEmpty) {
      unawaited(seedSubscriptionsFromServer());
    }
  }

  /// Merge the server's watched-channel set into the local list.
  ///
  /// Additive by construction: the server's set is global and lossy (see
  /// [YatteeClient.fetchWatchedChannels]), so it may omit channels the user
  /// subscribed to here and include ones they never did. Replacing the local
  /// list with it would silently drop the user's own choices, so entries are
  /// only ever added. The [YatteeSeedResult] says why nothing arrived when
  /// nothing does — the causes need different things from the user.
  Future<YatteeSeedResult> seedSubscriptionsFromServer() async {
    if (isDisposed) return const YatteeSeedResult(YatteeSeedOutcome.failed);
    final client = _client;
    if (client == null) return const YatteeSeedResult(YatteeSeedOutcome.failed);
    final userUuid = _activeUserUuid;
    final generation = _bindingGeneration;
    final List<YatteeSubscription> discovered;
    try {
      discovered = await client.fetchWatchedChannels();
    } on YatteeAuthException catch (e) {
      // 403 is the likely one: the channel list is admin-only, so a
      // secondary account on a shared server can never read it.
      appLogger.w('Yattee: the server refused its channel list (HTTP ${e.statusCode})');
      return YatteeSeedResult(
        e.statusCode == 403 ? YatteeSeedOutcome.notAdmin : YatteeSeedOutcome.failed,
        error: e.message,
      );
    } on YatteeApiException catch (e) {
      appLogger.w('Yattee: the server rejected the channel list request (HTTP ${e.statusCode})');
      return YatteeSeedResult(
        e.statusCode == 404 ? YatteeSeedOutcome.unsupported : YatteeSeedOutcome.failed,
        error: e.message,
      );
    } catch (e, stackTrace) {
      appLogger.w('Yattee: seeding subscriptions from the server failed', error: e, stackTrace: stackTrace);
      return YatteeSeedResult(YatteeSeedOutcome.failed, error: e.toString());
    }
    if (!_isCurrentBinding(userUuid, generation)) return const YatteeSeedResult(YatteeSeedOutcome.failed);
    if (discovered.isEmpty) return const YatteeSeedResult(YatteeSeedOutcome.empty);
    final known = {for (final subscription in _subscriptions) subscription.channelId};
    final added = [
      for (final subscription in discovered)
        if (!known.contains(subscription.channelId)) subscription,
    ];
    if (added.isEmpty) return const YatteeSeedResult(YatteeSeedOutcome.alreadyKnown);
    _subscriptions = [..._subscriptions, ...added];
    safeNotifyListeners();
    await _persistSubscriptions();
    appLogger.i('Yattee: seeded ${added.length} subscription(s) from the server');
    return YatteeSeedResult(YatteeSeedOutcome.imported, added: added.length);
  }

  /// Persist and bind a session the connect screen established.
  Future<void> adoptSession(YatteeSession session) async {
    if (isDisposed) return;
    final userUuid = _activeUserUuid;
    final generation = ++_bindingGeneration;
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    await _store.saveSession(userUuid, session);
    _setSessionAndRebind(userUuid, generation, session);
    // First connect on this device: pull whatever channels the server already
    // knows about so the user's existing Yattee subscriptions carry over.
    unawaited(seedSubscriptionsFromServer());
  }

  /// Forget the instance. Basic Auth has no server-side session to revoke.
  Future<void> disconnect() async {
    if (isDisposed) return;
    final userUuid = _activeUserUuid;
    final generation = ++_bindingGeneration;
    _subscriptions = const [];
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    await _store.clearSession(userUuid);
  }

  bool isSubscribed(String channelId) => _subscriptions.any((s) => s.channelId == channelId);

  Future<void> subscribe(YatteeSubscription subscription) async {
    if (isDisposed || isSubscribed(subscription.channelId)) return;
    _subscriptions = [subscription, ..._subscriptions];
    safeNotifyListeners();
    await _persistSubscriptions();
  }

  Future<void> unsubscribe(String channelId) async {
    if (isDisposed || !isSubscribed(channelId)) return;
    _subscriptions = [
      for (final s in _subscriptions)
        if (s.channelId != channelId) s,
    ];
    safeNotifyListeners();
    await _persistSubscriptions();
  }

  /// Writes the in-memory list to this profile's key. The key is captured
  /// before the await, so a profile switch mid-save still lands the old
  /// profile's list under the old profile's key rather than the new one's.
  Future<void> _persistSubscriptions() async {
    final userUuid = _activeUserUuid;
    try {
      await _store.saveSubscriptions(userUuid, _subscriptions);
    } catch (e) {
      _logPersistenceFailure(e);
    }
  }

  Future<void> setQuality(YatteeQuality quality) async {
    if (isDisposed || _quality == quality) return;
    _quality = quality;
    safeNotifyListeners();
    try {
      await _store.saveQuality(_activeUserUuid, quality);
    } catch (e) {
      _logPersistenceFailure(e);
    }
  }

  void _setSessionAndRebind(String userUuid, int generation, YatteeSession? session) {
    if (!_isCurrentBinding(userUuid, generation)) return;
    _session = session;
    _client?.dispose();
    // The auth service's client factory is a test seam (null in
    // production); sharing it lets one MockClient serve both.
    _client = session == null ? null : YatteeClient(session, httpClient: authService.httpClientFactory?.call());
    safeNotifyListeners();
  }

  bool _isCurrentBinding(String userUuid, int generation) {
    return !isDisposed && userUuid == _activeUserUuid && generation == _bindingGeneration;
  }

  @override
  void dispose() {
    _client?.dispose();
    _client = null;
    super.dispose();
  }
}
